import 'package:test/test.dart';

import 'package:iko_classroom/services/audio/speech_signal_enhancer.dart';

void main() {
  test('弱但有效的人声得到有限增益并保持峰值安全', () {
    const enhancer = SpeechSignalEnhancer();
    final output = enhancer.process(
      List<double>.generate(160, (i) => i.isEven ? 0.01 : -0.01),
    );

    expect(output.first.abs(), greaterThan(0.01));
    expect(output.every((sample) => sample.abs() <= 0.98), isTrue);
  });

  test('极低噪声不被自动放大', () {
    const enhancer = SpeechSignalEnhancer();
    final input = List<double>.filled(160, 0.001);
    final output = enhancer.process(input);

    expect(output, orderedEquals(input));
  });

  test('远场低电平语音片段不会被固定门槛漏掉', () {
    const enhancer = SpeechSignalEnhancer();
    final input = List<double>.generate(160, (i) => i.isEven ? 0.001 : -0.001);
    final output = enhancer.process(input);

    expect(output.first.abs(), greaterThan(input.first.abs()));
    expect(output.every((sample) => sample.abs() <= 0.98), isTrue);
  });
}
