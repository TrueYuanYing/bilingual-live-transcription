/// 中文课堂里常见英文产品名、技术词的本地规范化表。
///
/// 这不是“猜测整句”的模型，而是一个保守的术语救援层：只处理明确的
/// 常见拼写、空格变体和少量中文谐音，避免把普通中文过度改写。
class MixedLanguageTerms {
  MixedLanguageTerms._();

  static const Map<String, String> _aliases = {
    'claude codex': 'Claude Codex',
    'claud codex': 'Claude Codex',
    '克劳德codex': 'Claude Codex',
    '克劳德 codex': 'Claude Codex',
    'vibe coding': 'vibe coding',
    'vaib coding': 'vibe coding',
    'vibe科丁': 'vibe coding',
    'chat gpt': 'ChatGPT',
    'chatgpt': 'ChatGPT',
    '查特gpt': 'ChatGPT',
    '查 gpt': 'ChatGPT',
    'git hub': 'GitHub',
    'github': 'GitHub',
    '吉特哈布': 'GitHub',
    'deep seek': 'DeepSeek',
    'deepseek': 'DeepSeek',
    '深度求索ai': 'DeepSeek AI',
    'open ai': 'OpenAI',
    'openai': 'OpenAI',
    'codex': 'Codex',
    '可德克斯': 'Codex',
    '科德克斯': 'Codex',
    '柯德克斯': 'Codex',
    '哥德克斯': 'Codex',
    'claude': 'Claude',
    '克劳德': 'Claude',
    '克洛德': 'Claude',
    'flutter': 'Flutter',
    '佛拉特': 'Flutter',
    '弗拉特': 'Flutter',
    'python': 'Python',
    '派森': 'Python',
    'java script': 'JavaScript',
    'javascript': 'JavaScript',
    'type script': 'TypeScript',
    'typescript': 'TypeScript',
    'react': 'React',
    'api': 'API',
    'a p i': 'API',
    'ocr': 'OCR',
    'o c r': 'OCR',
    'ml kit': 'ML Kit',
    'mlkit': 'ML Kit',
    'sherpa': 'sherpa',
  };

  static final List<String> _orderedAliases = _aliases.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  /// 将术语替换成稳定拼写；大小写不敏感，最长别名优先。
  static String canonicalize(String text) {
    var result = text;
    for (final alias in _orderedAliases) {
      result = result.replaceAllMapped(
        RegExp(RegExp.escape(alias), caseSensitive: false),
        (_) => _aliases[alias]!,
      );
    }
    return result;
  }

  static int knownTermCount(String text) {
    final normalized = canonicalize(text);
    return {
      for (final canonical in _aliases.values) canonical.toLowerCase(),
    }.where((term) => normalized.toLowerCase().contains(term)).length;
  }

  static String get promptHint =>
      '术语优先规范：Codex、Claude、Claude Codex、ChatGPT、vibe coding、'
      'GitHub、DeepSeek、OpenAI、Flutter、Python、JavaScript、TypeScript、'
      'React、API、OCR、ML Kit。只在原句确实出现对应术语或明显谐音时修正。';
}
