/// Keep English terms found by the streaming bilingual recognizer, while
/// accepting a more complete Mandarin second pass when it does not erase them.
class DualPassResultPicker {
  static String pick(String streaming, String offline) {
    final first = streaming.trim();
    final second = offline.trim();
    if (second.isEmpty) return first;
    // Single-word second-pass guesses on classroom noise must not become
    // transcript lines or false alert triggers.
    if (first.isEmpty) return _chineseCount(second) >= 8 ? second : first;

    final protectedWords = RegExp(r'[A-Za-z]{2,}')
        .allMatches(first)
        .map((match) => match.group(0)!.toLowerCase())
        .toSet();
    final lowerSecond = second.toLowerCase();
    if (protectedWords.any((word) => !lowerSecond.contains(word))) {
      return first;
    }

    final firstChinese = _chineseCount(first);
    final secondChinese = _chineseCount(second);
    if (secondChinese < firstChinese * 0.8) return first;
    return second;
  }

  static int _chineseCount(String text) => text.runes
      .where((rune) =>
          rune >= 0x3400 && rune <= 0x9fff ||
          rune >= 0x20000 && rune <= 0x2fa1f)
      .length;
}
