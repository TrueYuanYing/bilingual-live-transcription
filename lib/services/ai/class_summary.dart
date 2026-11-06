/// 摘要只清理展示装饰，不改动公式里的乘号、下标和幂。
String plainClassSummary(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAllMapped(
        RegExp(r'(?<![\p{L}\p{N}_])\*\*(\S(?:[^\n]*?\S)?)\*\*(?![\p{L}\p{N}_])',
            unicode: true), (m) => m[1]!)
    .replaceAllMapped(
        RegExp(r'(?<![\p{L}\p{N}_])__(\S(?:[^\n]*?\S)?)__(?![\p{L}\p{N}_])',
            unicode: true), (m) => m[1]!)
    .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '')
    .replaceAll(RegExp(r'^```[^\n]*$', multiLine: true), '')
    .replaceAll(RegExp(r'^\s*(?:\*\s*){3,}$', multiLine: true), '')
    .replaceAll(RegExp(r'^[ \t]*\*[ \t]+', multiLine: true), '· ')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// 顺序完整覆盖原文，优先在句末分段；单个超长句也不突破请求上限。
List<String> classSummaryParts(String text) {
  const limit = 6000;
  final parts = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = (start + limit).clamp(0, text.length);
    if (end < text.length) {
      final boundary = text.lastIndexOf(RegExp(r'[。！？.!?\n]'), end - 1);
      if (boundary >= start + limit ~/ 2) end = boundary + 1;
      // Dart 字符索引为 UTF-16，不把一个 emoji 拆成无效代理字符。
      if (end > start &&
          text.codeUnitAt(end - 1) >= 0xD800 &&
          text.codeUnitAt(end - 1) <= 0xDBFF) {
        end--;
      }
    }
    parts.add(text.substring(start, end));
    start = end;
  }
  return parts;
}
