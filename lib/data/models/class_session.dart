/// 课堂记录、课表、关键词、设置等核心实体模型。
/// 纯 Dart 类，不依赖 Flutter / drift，便于测试与复用。
library;

/// 一次课堂录音会话。
class ClassSession {
  ClassSession({
    required this.id,
    required this.title,
    required this.courseName,
    required this.startedAt,
    this.endedAt,
    this.transcript = '',
    List<AlertEvent>? events,
    this.summary,
    this.language = 'zh',
  }) : events = events ?? [];

  final String id;
  final String title;
  final String courseName;
  final DateTime startedAt;

  /// 结束时间（录音中为 null，结束时写入）。
  DateTime? endedAt;

  /// 全文转写（可导出/摘要）。
  String transcript;

  /// 本次课堂触发的预警事件。
  List<AlertEvent> events;

  /// AI 摘要（Phase 3）。
  String? summary;

  /// 识别到的语言：zh / en ...
  String language;

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  bool get isRecording => endedAt == null;

  /// JSON 序列化，用于本地落库与导出。
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'courseName': courseName,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'transcript': transcript,
        'events': events.map((e) => e.toJson()).toList(),
        'summary': summary,
        'language': language,
      };

  factory ClassSession.fromJson(Map<String, dynamic> j) => ClassSession(
        id: j['id'] as String,
        title: j['title'] as String,
        courseName: j['courseName'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        endedAt: j['endedAt'] != null
            ? DateTime.parse(j['endedAt'] as String)
            : null,
        transcript: j['transcript'] as String? ?? '',
        events: AlertEventMerger.merge(((j['events'] as List<dynamic>?) ?? [])
            .map((e) => AlertEvent.fromJson(e as Map<String, dynamic>))),
        summary: j['summary'] as String?,
        language: j['language'] as String? ?? 'zh',
      );
}

/// 预警事件的类型。
enum AlertType { rollCall, question }

/// 一次点名 / 提问预警。
class AlertEvent {
  AlertEvent({
    required this.type,
    required this.timestamp,
    required this.triggerText,
    this.question,
    this.confidence = 1.0,
    this.isFinal = false,
    this.isCompleted = false,
    this.savedAnswer,
  });

  final AlertType type;
  final DateTime timestamp;

  /// 命中的原始转写片段。
  final String triggerText;

  /// 识别的提问内容（如有）。
  final String? question;

  /// 置信度 0~1：规则命中为 1，LLM 语义判断为模型输出。
  final double confidence;

  /// 识别器已定稿，可覆盖较长但错误的临时题干。
  final bool isFinal;

  /// Manual completion survives richer partial/final updates and session saves.
  bool isCompleted;
  String? savedAnswer;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'timestamp': timestamp.toIso8601String(),
        'triggerText': triggerText,
        'question': question,
        'confidence': confidence,
        'isFinal': isFinal,
        'isCompleted': isCompleted,
        'savedAnswer': savedAnswer,
      };

  factory AlertEvent.fromJson(Map<String, dynamic> j) => AlertEvent(
        type: AlertType.values.byName(j['type'] as String),
        timestamp: DateTime.parse(j['timestamp'] as String),
        triggerText: j['triggerText'] as String? ?? '',
        question: j['question'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
        isFinal: j['isFinal'] as bool? ?? false,
        isCompleted: j['isCompleted'] as bool? ?? false,
        savedAnswer: j['savedAnswer'] as String?,
      );
}

/// 合并同一次点名/提问在 partial、final 和滑动上下文窗口中产生的重复事件。
///
/// 识别器可能连续提交“不断变长”的同一段文本，因此不能只按字符串完全相等
/// 去重。时间窗口限制误合并范围，包含/前后缀相似度处理上下文窗口滑动。
class AlertEventMerger {
  const AlertEventMerger._();

  static const mergeWindow = Duration(seconds: 15);

  /// 同时点到本人并提问时，红色优先；超过事件窗口后允许新提醒替换。
  static AlertEvent? latestForDisplay(List<AlertEvent> events) {
    if (events.isEmpty) return null;
    final latest = events.last;
    for (final event in events.reversed) {
      if (latest.timestamp.difference(event.timestamp).abs() > mergeWindow) {
        break;
      }
      if (event.confidence >= .99 &&
          _similar(event.triggerText, latest.triggerText)) {
        return event;
      }
    }
    return latest;
  }

  static List<AlertEvent> merge(Iterable<AlertEvent> events) {
    final sorted = List<AlertEvent>.of(events)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final merged = <AlertEvent>[];
    for (final event in sorted) {
      final index = _findMergeIndex(merged, event);
      if (index < 0) {
        merged.add(event);
      } else {
        merged[index] = _mergePair(merged[index], event);
      }
    }
    return merged;
  }

  static int _findMergeIndex(List<AlertEvent> events, AlertEvent incoming) {
    for (var index = events.length - 1; index >= 0; index--) {
      final existing = events[index];
      // Completion ends this event; new windows must not inherit its status.
      if (existing.isCompleted) continue;
      final gap = incoming.timestamp.difference(existing.timestamp).abs();
      if (gap > mergeWindow) continue;
      final sameType = existing.type == incoming.type;
      final personalUpgrade = incoming.confidence >= 0.99 &&
          incoming.confidence > existing.confidence;
      if (sameType &&
          (personalUpgrade ||
              _similar(existing.triggerText, incoming.triggerText))) {
        return index;
      }
    }
    return -1;
  }

  static AlertEvent _mergePair(AlertEvent first, AlertEvent second) {
    final triggerText =
        !second.isFinal && first.triggerText.length > second.triggerText.length
            ? first.triggerText
            : second.triggerText;
    final firstQuestion = first.question?.trim() ?? '';
    final secondQuestion = second.question?.trim() ?? '';
    final question =
        !second.isFinal && firstQuestion.length > secondQuestion.length
            ? (firstQuestion.isEmpty ? null : firstQuestion)
            : (secondQuestion.isEmpty ? null : secondQuestion);
    return AlertEvent(
      type: first.type,
      // 首次命中时间作为事件身份，后续 richer 文本更新不会再次弹窗。
      timestamp: first.timestamp,
      triggerText: triggerText,
      question: question,
      confidence: first.confidence >= second.confidence
          ? first.confidence
          : second.confidence,
      isFinal: second.isFinal,
      isCompleted: first.isCompleted || second.isCompleted,
      savedAnswer: second.savedAnswer ?? first.savedAnswer,
    );
  }

  static bool _similar(String left, String right) {
    final a = _normalize(left);
    final b = _normalize(right);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b || a.contains(b) || b.contains(a)) return true;
    final shorter = a.length <= b.length ? a : b;
    if (shorter.length < 12) return false;
    final prefix = _commonPrefix(a, b);
    final suffix = _commonSuffix(a, b);
    return prefix / shorter.length >= 0.78 || suffix / shorter.length >= 0.78;
  }

  /// 对运行时去重开放的相似度判断；只比较预警短文本，不影响课堂正文。
  static bool similarText(String left, String right) => _similar(left, right);

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');

  static int _commonPrefix(String a, String b) {
    final limit = a.length < b.length ? a.length : b.length;
    var index = 0;
    while (index < limit && a.codeUnitAt(index) == b.codeUnitAt(index)) {
      index++;
    }
    return index;
  }

  static int _commonSuffix(String a, String b) {
    var left = a.length - 1;
    var right = b.length - 1;
    var count = 0;
    while (
        left >= 0 && right >= 0 && a.codeUnitAt(left) == b.codeUnitAt(right)) {
      count++;
      left--;
      right--;
    }
    return count;
  }
}
