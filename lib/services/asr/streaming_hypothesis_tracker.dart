/// 跟踪连续流式识别中的“已确认前缀”和当前假设。
///
/// Sherpa 的 partial 通常是从当前 utterance 开头不断增长的完整假设，而不是
/// 每次只返回新增 token。周期性保存时如果直接把 partial 当 final 并重置底层
/// decoder，下一次 partial 很容易丢掉正在说的音节，或者再次追加整句。这个小
/// 模块只处理文本边界，不依赖具体 ASR 实现，便于用纯 Dart 测试。
class StreamingHypothesisTracker {
  String _committed = '';
  String _latest = '';

  /// 当前 utterance 的完整假设；周期快照保留它以便 final 原位修订。
  String get latestHypothesis => _latest;

  /// 观察一个新的 partial，返回尚未被周期性确认的可显示尾部。
  String observe(String hypothesis) {
    _latest = _normalize(hypothesis);
    return _uncommitted(_latest);
  }

  /// 确认当前 partial，但不结束底层 ASR utterance。
  String commit() {
    final delta = _uncommitted(_latest);
    if (_latest.length >= _committed.length) {
      _committed = _latest;
    }
    return delta;
  }

  /// 接收真实 final，返回本段尚未写入正文的内容，并开启下一段。
  String finish(String hypothesis) {
    final delta = observe(hypothesis);
    reset();
    return delta;
  }

  void reset() {
    _committed = '';
    _latest = '';
  }

  String _uncommitted(String current) {
    if (current.isEmpty || _committed.isEmpty) return current;
    if (current.startsWith(_committed)) {
      return current.substring(_committed.length).trimLeft();
    }

    // 模型可能在尾部修正一两个字。优先消费已确认内容与当前假设之间的
    // 最长重叠，避免把同一段前缀再次写入正文；已确认正文不会被隐式改写。
    final overlap = _longestSuffixPrefixOverlap(_committed, current);
    if (overlap > 0) {
      return current.substring(overlap).trimLeft();
    }
    final commonPrefix = _commonPrefixLength(_committed, current);
    if (commonPrefix >= 2) {
      return current.substring(commonPrefix).trimLeft();
    }
    return current;
  }

  static int _longestSuffixPrefixOverlap(String committed, String current) {
    final max =
        committed.length < current.length ? committed.length : current.length;
    for (var length = max; length > 0; length--) {
      if (committed.substring(committed.length - length) ==
          current.substring(0, length)) {
        return length;
      }
    }
    return 0;
  }

  static int _commonPrefixLength(String left, String right) {
    final max = left.length < right.length ? left.length : right.length;
    var index = 0;
    while (index < max && left.codeUnitAt(index) == right.codeUnitAt(index)) {
      index++;
    }
    return index;
  }

  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
}
