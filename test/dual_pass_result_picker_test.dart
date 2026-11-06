import 'package:test/test.dart';
import 'package:iko_classroom/services/asr/dual_pass_result_picker.dart';

void main() {
  test('中文远场二次识别可替换漏词的流式结果', () {
    expect(
      DualPassResultPicker.pick('消费主义背后的逻辑', '消费主义背后的资本增值逻辑'),
      '消费主义背后的资本增值逻辑',
    );
  });

  test('保护流式识别到的英文术语', () {
    expect(
      DualPassResultPicker.pick('FREQUENTLY 是频繁地', '这个是平凡的'),
      'FREQUENTLY 是频繁地',
    );
  });

  test('空音频结果不会被误写进正文', () {
    expect(DualPassResultPicker.pick('', '嗯'), '');
    expect(DualPassResultPicker.pick('', ''), '');
  });
}
