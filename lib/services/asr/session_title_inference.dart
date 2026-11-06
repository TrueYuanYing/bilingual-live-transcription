/// 课堂标题的纯本地推断器。
///
/// 它只处理已经确认的文字，不调用网络，也不进入音频热路径。优先识别常见
/// 课程名，再从“学习/讲解/复习”后的短语提取本节主题。
class SessionTitleInference {
  const SessionTitleInference._();

  static const _genericTitles = {'', '自由课堂', '课堂记录', '未命名课堂'};

  static const _subjects = <String>[
    '毛泽东思想和中国特色社会主义理论体系概论',
    '马克思主义基本原理',
    '习近平新时代中国特色社会主义思想概论',
    '思想道德与法治',
    '概率论与数理统计',
    '大学生运动健康',
    '自动控制原理',
    '计算机组成原理',
    '计算机网络',
    '高等数学',
    '线性代数',
    '大学物理',
    '大学英语',
    '机械设计',
    '数据结构',
    '操作系统',
    '数据库原理',
    '软件工程',
    '数字电路',
    '模拟电路',
    '工程制图',
    '经济学',
    '管理学',
    '心理学',
    '大学体育',
  ];

  static String infer(String transcript, {String fallback = '自由课堂'}) {
    final text = transcript.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return fallback;

    final subject = _firstSubject(text);
    if (subject != null) {
      final topic = _topicAfterSubject(text, subject);
      return topic == null ? subject : '$subject · $topic';
    }

    final tools = <String>[
      if (RegExp(r'\bcodex\b', caseSensitive: false).hasMatch(text)) 'Codex',
      if (RegExp(r'\bclaude(?:\s+code)?\b', caseSensitive: false)
          .hasMatch(text))
        'Claude Code',
      if (RegExp(r'\bflutter\b', caseSensitive: false).hasMatch(text))
        'Flutter',
      if (RegExp(r'\bpython\b', caseSensitive: false).hasMatch(text)) 'Python',
      if (RegExp(r'\bjava\b', caseSensitive: false).hasMatch(text)) 'Java',
    ];
    if (tools.isNotEmpty) return tools.take(2).join(' 与 ');

    final cue = RegExp(
      r'(?:这节课|本节课|今天|接下来)?(?:我们)?(?:主要)?(?:学习|讲解|复习|讨论|介绍)(?:一下)?[：:]?([^，。！？；]{2,24})',
    ).firstMatch(text);
    final cueTopic = cue == null ? null : _cleanTopic(cue.group(1)!);
    if (cueTopic != null) return cueTopic;

    final first = text
        .replaceFirst(RegExp(r'^(?:大家|同学们)?(?:上午|下午|晚上)?好[，,。！!]?'), '')
        .split(RegExp(r'[，。！？；]'))
        .first
        .trim();
    if (first.length >= 4) {
      return first.length <= 16 ? first : '${first.substring(0, 16)}…';
    }
    return fallback;
  }

  static String normalizeTitle(String title, String transcript) {
    return _genericTitles.contains(title.trim())
        ? infer(transcript, fallback: title.trim().isEmpty ? '自由课堂' : title)
        : title;
  }

  static String? _firstSubject(String text) {
    String? best;
    var bestIndex = text.length;
    for (final subject in _subjects) {
      final index = text.indexOf(subject);
      if (index >= 0 && index < bestIndex) {
        best = subject;
        bestIndex = index;
      }
    }
    return best;
  }

  static String? _topicAfterSubject(String text, String subject) {
    final start = text.indexOf(subject) + subject.length;
    if (start < subject.length || start >= text.length) return null;
    final sentenceTail = text.substring(start).split(RegExp(r'[，。！？；]')).first;
    final cleaned = sentenceTail
        .replaceFirst(RegExp(r'^(?:中(?:的)?|里(?:的)?|的|课程中?|课上)[：:]?'), '')
        .trim();
    return _cleanTopic(cleaned);
  }

  static String? _cleanTopic(String raw) {
    var value = raw
        .replaceAll(RegExp(r'^(?:关于|一下|如何|怎么)'), '')
        .replaceAll(RegExp(r'(?:这|那)?(?:两个|几个)?(?:内容|知识点|软件)$'), '')
        .trim();
    if (value.length < 2 || value.startsWith('我们') || value.startsWith('大家')) {
      return null;
    }
    if (value.length > 14) value = value.substring(0, 14);
    return value;
  }
}
