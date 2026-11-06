import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_engine.dart';
import 'dual_pass_result_picker.dart';
import '../audio/speech_signal_enhancer.dart';

/// Worker-isolate-only native state. Never construct this on the UI isolate.
/// 支持中/英文切换：持有 baseDir 与 language，init 时拼出模型目录。
class SherpaNativeEngine implements AsrEngine, ResettableAsrSegment {
  SherpaNativeEngine({
    this.baseDir = '',
    this.language = 'zh',
    this.tokensFile = 'tokens.txt',
    this.encoderFile = 'encoder.int8.onnx',
    this.decoderFile = 'decoder.onnx',
    this.joinerFile = 'joiner.onnx',
  });

  /// 模型根目录（sherpa_models），init 时拼 `$baseDir/$language`。
  String baseDir;
  String language;
  final String tokensFile;
  final String encoderFile;
  final String decoderFile;
  final String joinerFile;

  final AsrStreamController _events = AsrStreamController();
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OfflineRecognizer? _offlineRecognizer;
  sherpa.OnlineStream? _stream;
  // The 80 ms input frame is reused, so buffered bytes must be copied.
  final BytesBuilder _segmentPcm = BytesBuilder();
  bool _inited = false;
  String? _loadedDir; // 当前已加载的模型目录，检测切换。
  String _lastPartialText = '';
  // 80 ms of PCM16/16 kHz: gain and endpoint checks must not depend on the
  // microphone driver's packet size. The buffer also preserves split samples.
  final Uint8List _pcmFrame = Uint8List(2560);
  int _pcmFrameLength = 0;
  final SpeechSignalEnhancer _signalEnhancer = const SpeechSignalEnhancer();

  @override
  Stream<AsrResult> get results => _events.stream;

  /// 切换语言（zh/en/auto）。下次 start 时重新加载对应模型。
  @override
  void setLanguage(String lang) {
    final normalized = switch (lang) {
      'en' => 'en',
      'auto' => 'auto',
      _ => 'zh',
    };
    if (language != normalized) {
      language = normalized;
      _inited = false;
      _loadedDir = null;
    }
  }

  /// 当前生效的模型目录。
  String get modelDir => '$baseDir/$language';

  String? get loadedModelDirectory => _loadedDir;

  bool get isModelLoaded => _recognizer != null && _loadedDir == modelDir;

  @override
  Future<void> init() async {
    await sherpa.initBindingsAsync();
    _pcmFrameLength = 0;
    if (_inited && _loadedDir == modelDir && _recognizer != null) {
      _startFreshStream(_recognizer!);
      return;
    }
    final dir = modelDir;
    if (baseDir.isEmpty) {
      throw StateError('模型目录未设置');
    }
    final requiredFiles = [encoderFile, decoderFile, joinerFile, tokensFile];
    final missing = requiredFiles.where((file) {
      final model = File('$dir/$file');
      return !model.existsSync() || model.lengthSync() == 0;
    }).toList();
    if (missing.isNotEmpty) {
      final languageName = switch (language) {
        'en' => '英文',
        'auto' => '中英混合',
        _ => '中文',
      };
      throw StateError('缺少$languageName模型文件：${missing.join(', ')}');
    }
    final config = sherpa.OnlineRecognizerConfig(
      feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$dir/$encoderFile',
          decoder: '$dir/$decoderFile',
          joiner: '$dir/$joinerFile',
        ),
        tokens: '$dir/$tokensFile',
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      enableEndpoint: true,
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    );
    _stream?.free();
    _stream = null;
    _offlineRecognizer?.free();
    _offlineRecognizer = null;
    _recognizer?.free();
    _recognizer = null;
    _recognizer = sherpa.OnlineRecognizer(config);
    if (language == 'auto') {
      final model = File('$dir/model.int8.onnx');
      final tokens = File('$dir/offline-tokens.txt');
      if (model.existsSync() && tokens.existsSync()) {
        // The streaming pass remains authoritative for partial subtitles.
        // SenseVoice runs only on bounded finalized segments on this worker.
        try {
          _offlineRecognizer = sherpa.OfflineRecognizer(
            sherpa.OfflineRecognizerConfig(
              model: sherpa.OfflineModelConfig(
                senseVoice: sherpa.OfflineSenseVoiceModelConfig(
                  model: model.path,
                  language: 'auto',
                ),
                tokens: tokens.path,
                numThreads: 2,
                debug: false,
              ),
            ),
          );
        } catch (error) {
          if (Platform.environment['IKO_ASR_TRACE'] == '1') {
            stderr.writeln('offline init: $error');
          }
          // Keep the working streaming model available if the optional pass
          // cannot load on a device with insufficient memory.
          _offlineRecognizer = null;
        }
      }
    }
    _stream = _recognizer!.createStream();
    _loadedDir = dir;
    _inited = true;
    _lastPartialText = '';
  }

  @override
  void acceptAudio(List<int> pcmBytes) {
    if (_recognizer == null || _stream == null || pcmBytes.isEmpty) return;
    var offset = 0;
    while (offset < pcmBytes.length) {
      final length = (pcmBytes.length - offset)
          .clamp(0, _pcmFrame.length - _pcmFrameLength);
      _pcmFrame.setRange(
          _pcmFrameLength, _pcmFrameLength + length, pcmBytes, offset);
      _pcmFrameLength += length;
      offset += length;
      if (_pcmFrameLength == _pcmFrame.length) {
        _pcmFrameLength = 0;
        _decodePcm(_pcmFrame);
      }
    }
  }

  void _decodePcm(Uint8List bytes) {
    final rec = _recognizer;
    final stream = _stream;
    if (rec == null || stream == null || bytes.isEmpty) return;
    if (_offlineRecognizer != null) _segmentPcm.add(bytes);
    final floats = Float32List.fromList(
      _signalEnhancer.process(_int16ToFloat32(bytes)),
    );
    if (floats.isEmpty) return;
    stream.acceptWaveform(samples: floats, sampleRate: 16000);
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    final t = rec.getResult(stream).text.trim();
    if (rec.isEndpoint(stream)) {
      final finalText = _refineFinal(t);
      if (finalText.isNotEmpty) {
        _events.add(AsrResult(
            text: finalText,
            isFinal: true,
            timestamp: DateTime.now(),
            language: language));
      }
      _startFreshStream(rec);
    } else if (t.isNotEmpty) {
      if (t == _lastPartialText) return;
      _lastPartialText = t;
      _events.add(AsrResult(
          text: t,
          isFinal: false,
          timestamp: DateTime.now(),
          language: language));
    }
  }

  String _refineFinal(String streamingText) {
    final recognizer = _offlineRecognizer;
    final bytes = _segmentPcm.takeBytes();
    if (recognizer == null || bytes.length < 16000) return streamingText;
    final samples = _int16ToFloat32(bytes);
    var energy = 0.0;
    for (final sample in samples) {
      energy += sample * sample;
    }
    if (energy / samples.length < 0.000004) return streamingText;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final offlineText = recognizer.getResult(stream).text;
      final picked = DualPassResultPicker.pick(streamingText, offlineText);
      if (Platform.environment['IKO_ASR_TRACE'] == '1') {
        stderr.writeln('online=$streamingText | offline=$offlineText | picked=$picked');
      }
      return picked;
    } catch (error) {
      if (Platform.environment['IKO_ASR_TRACE'] == '1') {
        stderr.writeln('offline decode: $error');
      }
      return streamingText;
    } finally {
      stream.free();
    }
  }

  @override
  void resetCurrentSegment() {
    final rec = _recognizer;
    if (rec == null || _stream == null) return;
    _pcmFrameLength = 0;
    _startFreshStream(rec);
  }

  @override
  Future<void> finish() async {
    // Flush the last short frame before right-context padding. Keep no bytes
    // across sessions; an incomplete final PCM16 sample cannot be decoded.
    if (_pcmFrameLength >= 2) {
      _decodePcm(Uint8List.sublistView(
          _pcmFrame, 0, _pcmFrameLength - _pcmFrameLength % 2));
    }
    _pcmFrameLength = 0;
    final rec = _recognizer;
    final stream = _stream;
    if (rec == null || stream == null) return;
    // Zipformer needs right-context frames to emit the final words. Supply
    // silence before marking input finished, as in Sherpa's streaming examples.
    stream.acceptWaveform(samples: Float32List(12800), sampleRate: 16000);
    stream.inputFinished();
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    final t = _refineFinal(rec.getResult(stream).text.trim());
    if (t.isNotEmpty) {
      _events.add(AsrResult(
          text: t,
          isFinal: true,
          timestamp: DateTime.now(),
          language: language));
    }
    _startFreshStream(rec);
  }

  @override
  Future<void> dispose() async {
    _stream?.free();
    _stream = null;
    _offlineRecognizer?.free();
    _offlineRecognizer = null;
    _recognizer?.free();
    _recognizer = null;
    _inited = false;
    _pcmFrameLength = 0;
    await _events.close();
  }

  Float32List _int16ToFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// 端点后创建新的 stream，而不是复用 reset 后的旧 stream。
  ///
  /// Sherpa 的在线识别器在 reset 后可能把下一段开头 token 留在旧的
  /// decoder 状态里；新 stream 只继承 recognizer 配置，不继承上一段神经状态。
  void _startFreshStream(sherpa.OnlineRecognizer recognizer) {
    _stream?.free();
    _stream = recognizer.createStream();
    _segmentPcm.clear();
    _lastPartialText = '';
  }
}
