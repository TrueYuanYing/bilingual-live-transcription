/// 自动识别字幕的语言稳定器。
///
/// 双模型并行时，单个 partial 可能只是噪声或模型幻觉。只有连续观察到同一
/// 候选，且脚本文字达到最低证据量，才允许切换当前字幕语言。
class SpeechLanguageStabilizer {
  String? _stableLanguage;
  String? _candidateLanguage;
  int _candidateStreak = 0;

  String? get stableLanguage => _stableLanguage;

  String accept({
    required String language,
    required String text,
    required bool isFinal,
  }) {
    final normalized = language == 'en' ? 'en' : 'zh';
    if (_stableLanguage == null) {
      _stableLanguage = normalized;
      return normalized;
    }
    if (_stableLanguage == normalized) {
      _candidateLanguage = null;
      _candidateStreak = 0;
      return normalized;
    }

    final evidence = _evidence(text, normalized);
    final minimum = normalized == 'en' ? 6 : 2;
    if (evidence < minimum) return _stableLanguage!;

    if (_candidateLanguage == normalized) {
      _candidateStreak++;
    } else {
      _candidateLanguage = normalized;
      _candidateStreak = 1;
    }

    // final 是完整句，强证据可立即切换；partial 需要连续 3 次确认。
    if ((isFinal && evidence >= minimum + 2) || _candidateStreak >= 3) {
      _stableLanguage = normalized;
      _candidateLanguage = null;
      _candidateStreak = 0;
    }
    return _stableLanguage!;
  }

  void reset() {
    _stableLanguage = null;
    _candidateLanguage = null;
    _candidateStreak = 0;
  }

  static int _evidence(String text, String language) {
    if (language == 'en') return RegExp(r'[A-Za-z]').allMatches(text).length;
    return RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]').allMatches(text).length;
  }
}
