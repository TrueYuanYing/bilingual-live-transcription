import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';

import 'stereo_pcm_decimator.dart';

/// 音频采集配置。
class AudioConfig {
  const AudioConfig({
    this.sampleRate = 16000,
    this.numChannels = 1,
    this.noiseSuppress = false,
    this.farField = false,
  });

  final int sampleRate;
  final int numChannels;
  final bool noiseSuppress;
  final bool farField;
}

/// 采集到的音频块（PCM 16bit 单声道，字节流）。
typedef AudioChunk = Uint8List;

/// 音频采集抽象：负责从麦克风/蓝牙取 PCM 流。
abstract class AudioCapture {
  Stream<AudioChunk> get stream;
  Future<bool> requestPermission();
  Future<void> start(AudioConfig config, {int bufferSize});
  Future<void> stop();
  Future<bool> isRecording();
}

/// 基于 `record` 插件的麦克风/蓝牙采集实现。
/// 输出 16k 单声道 PCM 流，供 ASR 消费。
class RecordAudioCapture implements AudioCapture {
  AudioRecorder? _recorder; // 每次 start 新建，避免 stop 后复用导致 startStream 失效。
  final StreamController<AudioChunk> _controller =
      StreamController<AudioChunk>.broadcast();
  StreamSubscription<AudioChunk>? _recorderSub;
  bool _recording = false;

  @override
  Stream<AudioChunk> get stream => _controller.stream;

  @override
  Future<bool> requestPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted || status.isLimited;
  }

  @override
  Future<void> start(AudioConfig config, {int bufferSize = 1024}) async {
    if (_recording) return;
    if (!await requestPermission()) {
      throw StateError('麦克风权限被拒绝');
    }
    // 每次 start 创建全新的 AudioRecorder，规避 record 插件
    // "同一实例 stop 后无法再次 startStream" 的问题。
    _recorder = AudioRecorder();
    try {
      RecordConfig recordConfig(AndroidAudioSource source,
              {int? sampleRate, int? numChannels}) =>
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: sampleRate ?? config.sampleRate,
            numChannels: numChannels ?? config.numChannels,
            autoGain: true,
            noiseSuppress: config.noiseSuppress,
            androidConfig: AndroidRecordConfig(audioSource: source),
          );
      Stream<Uint8List> s;
      StereoPcmDecimator? decimator;
      try {
        if (config.farField) {
          // Match this device's classroom recorder input. CAMCORDER routed to
          // its rear microphone, which did not reproduce the recorded sample.
          s = await _recorder!.startStream(recordConfig(
            AndroidAudioSource.mic,
            sampleRate: 48000,
            numChannels: 2,
          ));
          decimator = StereoPcmDecimator();
        } else {
          s = await _recorder!
              .startStream(recordConfig(AndroidAudioSource.voiceRecognition));
        }
      } catch (_) {
        if (!config.farField) rethrow;
        // Some microphones do not support stereo PCM streaming.
        await _recorder!.dispose();
        _recorder = AudioRecorder();
        s = await _recorder!
            .startStream(recordConfig(AndroidAudioSource.voiceRecognition));
      }
      _recorderSub = s.listen(
        (chunk) {
          final output = decimator?.convert(chunk) ?? chunk;
          if (output.isNotEmpty) _controller.add(output);
        },
        onError: _controller.addError,
      );
      _recording = true;
    } catch (_) {
      await _recorder?.dispose();
      _recorder = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    final subscription = _recorderSub;
    _recorder = null;
    _recorderSub = null;
    _recording = false;
    try {
      await recorder?.stop();
    } finally {
      await subscription?.cancel();
      await recorder?.dispose();
    }
    // 注意：不 close controller —— 它要在多次 start/stop 间复用。
  }

  @override
  Future<bool> isRecording() async => _recording;
}
