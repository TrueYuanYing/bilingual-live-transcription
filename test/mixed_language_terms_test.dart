import 'package:test/test.dart';

import 'package:iko_classroom/services/asr/mixed_language_terms.dart';

void main() {
  test('保留中文语境并规范常见英文术语', () {
    const input = '大家下午好，我们这节课学习可德克斯和克劳德 codex这两个软件，来做vibe科丁';
    final output = MixedLanguageTerms.canonicalize(input);

    expect(output, contains('Codex'));
    expect(output, contains('Claude Codex'));
    expect(output, contains('vibe coding'));
    expect(output, startsWith('大家下午好'));
  });
}
