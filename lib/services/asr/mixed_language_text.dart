/// 混合语言字幕工具：保留中英文边界，同时按整句主要语言保持稳定显示。
library;

enum TranscriptSpanLanguage { chinese, english, neutral }

class TranscriptSpan {
  const TranscriptSpan({required this.text, required this.language});

  final String text;
  final TranscriptSpanLanguage language;
}

class MixedLanguageText {
  MixedLanguageText._();

  static final _spanPattern = RegExp(
    r"[A-Za-z]+(?:['’\-][A-Za-z]+)*|[\u3400-\u4DBF\u4E00-\u9FFF]+|[^A-Za-z\u3400-\u4DBF\u4E00-\u9FFF]+",
  );

  static List<TranscriptSpan> spans(String text) {
    if (text.isEmpty) return const [];
    final result = <TranscriptSpan>[];
    for (final match in _spanPattern.allMatches(text)) {
      final value = match.group(0)!;
      final language = _languageOf(value);
      if (language == TranscriptSpanLanguage.neutral && result.isNotEmpty) {
        final previous = result.removeLast();
        result.add(TranscriptSpan(
          text: '${previous.text}$value',
          language: previous.language,
        ));
      } else {
        result.add(TranscriptSpan(text: value, language: language));
      }
    }
    final merged = <TranscriptSpan>[];
    for (final span in result) {
      if (merged.isNotEmpty && merged.last.language == span.language) {
        final previous = merged.removeLast();
        merged.add(TranscriptSpan(
          text: '${previous.text}${span.text}',
          language: previous.language,
        ));
      } else {
        merged.add(span);
      }
    }
    return merged;
  }

  static bool hasEnglish(String text) => RegExp(r'[A-Za-z]{2,}').hasMatch(text);

  static bool hasChinese(String text) =>
      RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]').hasMatch(text);

  static String primaryLanguage(String text, {String fallback = 'zh'}) {
    var chinese = 0;
    var latin = 0;
    for (final rune in text.runes) {
      if (_isChinese(rune)) {
        chinese++;
      } else if (_isLatin(rune)) {
        latin++;
      }
    }
    if (chinese == 0 && latin == 0) return fallback;
    if (chinese == 0) return 'en';
    if (latin == 0) return 'zh';
    // 中文为主时保留中文状态；只有英文明显占主导才切换。
    return chinese >= latin ~/ 2 ? 'zh' : 'en';
  }

  static TranscriptSpanLanguage _languageOf(String value) {
    if (value.runes.any(_isChinese)) return TranscriptSpanLanguage.chinese;
    if (value.runes.any(_isLatin)) return TranscriptSpanLanguage.english;
    return TranscriptSpanLanguage.neutral;
  }

  static bool _isChinese(int rune) =>
      (rune >= 0x3400 && rune <= 0x4DBF) || (rune >= 0x4E00 && rune <= 0x9FFF);

  static bool _isLatin(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);
}
