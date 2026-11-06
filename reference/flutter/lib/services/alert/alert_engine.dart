import '../../data/models/class_session.dart';
import '../../data/models/keyword_pack.dart';
import 'name_matcher.dart';

/// 一条命中结果。
class AlertHit {
  const AlertHit({
    required this.type,
    required this.triggerText,
    this.question,
    this.confidence = 1.0,
  });
  final AlertType type;
  final String triggerText;
  final String? question;
  final double confidence;
}

/// 预警卡片使用的短文本整理器。
///
/// ASR 的滑动上下文往往包含前面十几秒的讲解，直接把整个窗口放进问题卡片
/// 会让用户看不到真正的问题。这里保留最近的问题引导词，并设置硬上限；
/// 不改变原始课堂正文，只改变预警展示字段。
class AlertTextCompactor {
  const AlertTextCompactor._();

  static const defaultMaxLength = 72;

  static String compact(String text, {int maxLength = defaultMaxLength}) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty || maxLength <= 0) return '';

    // 仅压缩展示长度；不能从最后一个疑问词切开复合题或丢掉题设。
    final candidate = normalized;
    if (candidate.length <= maxLength) return candidate;

    // 句尾优先：问题通常在最后一个问号前结束。
    final punctuation = RegExp(r'[。！？!?]');
    final end = punctuation.firstMatch(candidate)?.start;
    final sentence =
        end != null ? candidate.substring(0, end).trim() : candidate;
    final source = sentence.isEmpty ? candidate : sentence;
    if (source.length <= maxLength) return source;
    return '${source.substring(0, maxLength - 1).trim()}…';
  }

  static String? compactNullable(String? text,
      {int maxLength = defaultMaxLength}) {
    if (text == null) return null;
    final value = compact(text, maxLength: maxLength);
    return value.isEmpty ? null : value;
  }
}

/// 点名 / 提问预警引擎。
///
/// 输入：转写流的新片段（增量 `partial` 或已定稿 `final`）。
/// 输出：命中 [AlertType.rollCall] / [AlertType.question] 的 [AlertHit]。
///
/// 设计为纯 Dart、无副作用，便于单元测试；上层负责弹窗。
/// 采用「规则 + 关键词包」本地匹配，未来可再接 LLM 语义层。
class AlertEngine {
  AlertEngine({
    KeyedKeywords? keywords,
    String? studentName,
    String? studentId,
  })  : _custom = keywords ?? KeyedKeywords(const []),
        _studentName = studentName,
        _studentId = studentId;

  // 内置通用规则（正则），覆盖点名/提问最常见的句式。
  // RegExp 非 const，用 static final。
  static final List<RegExp> _rollCallRegs = [
    RegExp(r'点(个|一下|到)?名'),
    RegExp(r'抽(个|人|一下|几位)?(同学|人)?(来)?(回答|答|说|上讲台)'),
    RegExp(r'(来|请|叫|喊)?(这位|这位同学|那个|那边)?(同学|这位)?(来)?回答'),
    RegExp(r'(我|老师)?(随机点|随机抽|课堂提问|开始提问)'),
    RegExp(r'下面(我)?(们)?(点个名|抽个问|提问|抽查|考勤)'),
    RegExp(r'\b(?:please\s+)?(?:call\s+on|pick\s+on|ask)\s+(?:a\s+)?student\b',
        caseSensitive: false),
    RegExp(r'\b(?:can|could)\s+you\s+(?:come|answer|respond|explain)\b',
        caseSensitive: false),
    RegExp(r'\b(?:your|the)\s+turn\s+to\s+answer\b', caseSensitive: false),
  ];

  static final List<RegExp> _questionRegs = [
    RegExp(r'谁(来|能|知道|说一下|回答)'),
    RegExp(r'(这个问题|这道题|这个知识点|上面的内容)(谁|大家|有谁知道)'),
    RegExp(r'(为什么|如何|怎么|是什么|对不对|是否)(呢)?'),
    RegExp(r'(举个|给我个|举个例子|举个例子说明)'),
    RegExp(r'(想(一下|一想|请问)|思考(一下|这件事)(然后)?(回答)?)'),
    RegExp(r'(请|大家)?(说说|谈一谈|分析一下|解释一下|总结一下)'),
    RegExp(r'\b(?:who\s+can|does\s+anyone\s+know|can\s+anyone\s+explain)\b',
        caseSensitive: false),
    RegExp(
        r'\b(?:why|how|what\s+is|what\s+are|which|does|do|can)\b[^.!?]{0,120}[?？]',
        caseSensitive: false),
    RegExp(r'^\s*(?:why|how|what|when|where|which|can|could|do|does)\b',
        caseSensitive: false),
    RegExp(r'\b(?:please\s+)?(?:explain|analyze|summarize|tell\s+me)\b',
        caseSensitive: false),
  ];

  // 当前生效的开关（custom 关键词包 + 内置规则开关）。
  final KeyedKeywords _custom;
  bool _useBuiltIn = true;
  String? _studentName;
  String? _studentId;

  /// 设置/更新学生身份，用于个人化点名识别。
  void setStudentIdentity({String? name, String? id}) {
    _studentName = name;
    _studentId = id;
  }

  /// 切换内置规则是否生效（配合关键词包自定义）。
  void setUseBuiltInRules(bool value) => _useBuiltIn = value;

  /// 处理一段新增的转写文本，返回命中的预警（可能多个/0 个）。
  ///
  /// [isFinal] 表示该片段是否已定稿；part 未定稿的片段也参与匹配，
  /// 以保证"点名"刚出口就能弹窗，不必等一句话说完。
  List<AlertHit> process(String text, {bool isFinal = true}) {
    if (text.isEmpty) return const [];
    final hits = <AlertHit>[];
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];

    // 1) 学生姓名/学号个人化点名：命中即高优先级。
    if (_studentName != null && _studentName!.isNotEmpty) {
      final nameHit = _matchStudentName(trimmed, _studentName!);
      if (nameHit != null) hits.add(nameHit);
    }
    if (_studentId != null && _studentId!.isNotEmpty) {
      final idHit = _matchStudentId(trimmed, _studentId!);
      if (idHit != null) hits.add(idHit);
    }

    // 2) 内置规则。
    if (_useBuiltIn) {
      for (final reg in _rollCallRegs) {
        if (reg.hasMatch(trimmed)) {
          hits.add(AlertHit(
            type: AlertType.rollCall,
            triggerText: trimmed,
            confidence: 0.95,
          ));
          break;
        }
      }
      for (final reg in _questionRegs) {
        if (reg.hasMatch(trimmed)) {
          hits.add(AlertHit(
            type: AlertType.question,
            triggerText: trimmed,
            question: _extractQuestion(trimmed),
            confidence: 0.85,
          ));
          break;
        }
      }
    }

    // 3) 用户关键词包（含课程专用词）。
    for (final kw in _custom.enabledRollCallWords) {
      if (_containsKeyword(trimmed, kw)) {
        hits.add(AlertHit(
          type: AlertType.rollCall,
          triggerText: trimmed,
          confidence: 0.9,
        ));
      }
    }
    for (final kw in _custom.enabledQuestionWords) {
      if (_containsKeyword(trimmed, kw)) {
        hits.add(AlertHit(
          type: AlertType.question,
          triggerText: trimmed,
          question: _extractQuestion(trimmed),
          confidence: 0.8,
        ));
      }
    }

    // 4) 去重：同一片段对同一类型的命中只保留置信度最高的一条。
    return _dedupe(hits);
  }

  AlertHit? _matchStudentName(String text, String name) {
    // 先做字面匹配，再做读音匹配，覆盖同音错字与英文姓名大小写差异。
    if (NameMatcher.matchesName(text, name)) {
      return AlertHit(
        type: AlertType.rollCall,
        triggerText: text,
        question: _extractQuestion(text),
        // 姓名只和当前设备保存的本人资料比对；同音/单字 ASR 容错一旦
        // 命中，也应升级为红色本人预警，而不是被通用黄色规则覆盖。
        confidence: 1.0,
      );
    }
    return null;
  }

  bool _containsKeyword(String text, String keyword) =>
      text.toLowerCase().contains(keyword.toLowerCase());

  AlertHit? _matchStudentId(String text, String id) {
    if (NameMatcher.matchesStudentId(text, id)) {
      return AlertHit(
        type: AlertType.rollCall,
        triggerText: text,
        question: _extractQuestion(text),
        confidence: 1.0,
      );
    }
    return null;
  }

  /// 从语句里粗略抽出问题主体（用于弹窗告知内容）。
  /// 规则简化：去掉人称/引导词，保留问题核心。
  String? _extractQuestion(String text) {
    var q = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Sliding ASR windows contain several seconds of lecture context. Keep the
    // question card focused on the latest interrogative clause; the complete
    // window remains available to QuestionContext for AI reasoning.
    final cue = RegExp(
      r'(为什么|为何|如何|怎么(?:样|办)?|是什么|哪些|是否|谁(?:来|能|知道)?|'
      r'why\b|how\b|what\b|which\b|who\b)',
      caseSensitive: false,
    );
    final cueMatches = cue.allMatches(q).toList();
    if (cueMatches.isNotEmpty) {
      final lastBoundary = RegExp(r'[。！？!?]')
          .allMatches(q)
          .where((match) => match.end < q.length)
          .toList();
      final boundaryEnd = lastBoundary.isEmpty ? 0 : lastBoundary.last.end;
      final trailing = cueMatches.where((match) => match.start >= boundaryEnd).toList();
      // Preserve a compound question (为什么……，如何……) when it is the
      // current short tail; otherwise prefer the latest cue in a long window.
      final firstTrailing = trailing.isEmpty ? cueMatches.last : trailing.first;
      final candidate = q.length - firstTrailing.start;
      final selected = candidate <= 120 ? firstTrailing : cueMatches.last;
      q = q.substring(selected.start).trimLeft();
    } else {
      final boundaries = RegExp(r'[。！？!?；;]').allMatches(q).toList();
      if (boundaries.isNotEmpty) q = q.substring(boundaries.last.end).trim();
    }
    for (final lead in [
      '你来回答一点',
      '你来回答',
      '说说',
      '回答一下',
      '请回答',
      '分析一下',
      '解释一下',
    ]) {
      q = q.replaceAll(lead, '');
    }
    q = q.trim();
    while (q.endsWith('一下') || q.endsWith('吧') || q.endsWith('呢')) {
      q = q.endsWith('一下')
          ? q.substring(0, q.length - 2)
          : q.substring(0, q.length - 1);
    }
    if (q.length > AlertTextCompactor.defaultMaxLength) {
      q = '${q.substring(0, AlertTextCompactor.defaultMaxLength - 1).trim()}…';
    }
    return q.isEmpty ? null : q;
  }

  List<AlertHit> _dedupe(List<AlertHit> hits) {
    final byType = <AlertType, AlertHit>{};
    for (final h in hits) {
      final existing = byType[h.type];
      if (existing == null || h.confidence > existing.confidence) {
        byType[h.type] = h;
      }
    }
    return byType.values.toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
  }
}

/// 关键词包在预警引擎视角下的只读投影（只暴露启用的弱/强词）。
class KeyedKeywords {
  KeyedKeywords(this._packs);
  final List<KeywordPack> _packs;

  List<String> get enabledRollCallWords => _wordsOf(KeywordKind.rollCall);
  List<String> get enabledQuestionWords => _wordsOf(KeywordKind.question);

  List<String> _wordsOf(KeywordKind kind) {
    final out = <String>[];
    for (final pack in _packs) {
      for (final kw in pack.keywords) {
        if (kw.enabled && kw.kind == kind) out.add(kw.text);
      }
    }
    return out;
  }
}
