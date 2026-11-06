/// 限制实时字幕页每帧参与排版的正文长度。
///
/// 完整文本始终保存在 [ClassSession]；这里只裁剪屏幕上的历史窗口，避免一节
/// 长课积累数万字后，每次 partial 更新都重新布局整篇正文。
class LiveTranscriptWindow {
  const LiveTranscriptWindow._();

  static String tail(String fullText, {int maxCharacters = 6000}) {
    if (maxCharacters <= 0 || fullText.length <= maxCharacters) return fullText;
    var start = fullText.length - maxCharacters;
    final codeUnit = fullText.codeUnitAt(start);
    if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) start++;
    return '…\n${fullText.substring(start)}';
  }
}

/// 听写正文的跟随策略，与 Flutter 滚动组件分离，便于测试和保持手感稳定。
class LiveTranscriptFollowPolicy {
  LiveTranscriptFollowPolicy({this.threshold = 72});

  final double threshold;
  bool followLatest = true;
  bool showReturnToLatest = false;

  /// 返回当前是否仍处于“接近最新位置”。
  bool update({required double offset, required double maxExtent}) {
    final nearLatest = maxExtent - offset <= threshold;
    followLatest = nearLatest;
    showReturnToLatest = !nearLatest;
    return nearLatest;
  }
}
