import 'dart:math' as math;

/// 进入 ASR 前的轻量语音能量整理。
///
/// 只对已经高于极低噪声门限的弱信号做有限增益，并始终限制峰值；
/// 不做激进降噪，也不改变采样率，避免把远处的尖细人声一并削掉。
class SpeechSignalEnhancer {
  const SpeechSignalEnhancer({
    this.noiseGate = 0.0005,
    this.targetRms = 0.075,
    this.maxGain = 3.0,
  });

  final double noiseGate;
  final double targetRms;
  final double maxGain;

  List<double> process(List<double> samples) {
    if (samples.isEmpty) return samples;
    var energy = 0.0;
    var sum = 0.0;
    var peak = 0.0;
    for (final sample in samples) {
      energy += sample * sample;
      sum += sample;
      peak = math.max(peak, sample.abs());
    }
    final mean = sum / samples.length;
    // A fixed DC offset is not speech; gate on the varying signal energy.
    final rms = math.sqrt(math.max(0.0, energy / samples.length - mean * mean));
    if (rms < noiseGate || peak <= 0.0001) return samples;

    final gain = math.min(maxGain, math.max(1.0, targetRms / rms));
    // 保留峰值余量，避免放大后硬削波破坏辅音。
    final safeGain = math.min(gain, 0.94 / peak);
    if (safeGain <= 1.001) return samples;
    return [
      for (final sample in samples)
        (sample * safeGain).clamp(-0.98, 0.98).toDouble(),
    ];
  }
}
