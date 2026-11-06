/// 可选的本地转写整理器。
///
/// 这是一个不依赖云端的保守整理层：只规范明显的中英文标点、在已有句末
/// 标点后换行，并在很长的无标点片段遇到常见转折词时分段。默认不启用，
/// 因而不会改变原有听写行为；打开后也不会把内容上传到外部模型。
class LocalTranscriptRefiner {
  const LocalTranscriptRefiner._();

  static String refine(String input) {
    var text = input.trim();
    if (text.isEmpty) return '';
    text = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('，,', '，')
        .replaceAll(',，', '，')
        .replaceAll(',,', ',')
        .replaceAll('!!', '！')
        .replaceAll('??', '？')
        .trim();

    // 只在句末标点后断行，不凭空添加标点，避免改变老师原话。
    text = text.replaceAllMapped(
      RegExp(r'([。！？!?；;])\s*'),
      (match) => '${match.group(1)}\n',
    );
    text = _splitLongUnpunctuatedClauses(text);
    return text
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .trim();
  }

  static String _splitLongUnpunctuatedClauses(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    final discourse = RegExp(r'(首先|其次|然后|但是|不过|因此|所以|最后|另外|也就是说)');
    for (final line in lines) {
      if (line.length < 86 || line.contains('，')) {
        out.add(line);
        continue;
      }
      var current = line;
      while (current.length >= 86) {
        final matches = discourse.allMatches(current).toList();
        final split = matches
            .map((match) => match.start)
            .where((index) => index >= 28 && index <= 86)
            .lastOrNull;
        if (split == null) break;
        out.add(current.substring(0, split).trim());
        current = current.substring(split).trim();
      }
      out.add(current);
    }
    return out.join('\n');
  }
}
