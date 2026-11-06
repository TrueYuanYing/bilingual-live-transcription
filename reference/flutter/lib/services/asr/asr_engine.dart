/// 语音识别引擎抽象。统一本地 sherpa 与云端 ASR 接口。
library;

import 'dart:async';

/// 一次转写结果。
class AsrResult {
  const AsrResult({
    required this.text,
    required this.isFinal,
    required this.timestamp,
    this.language = 'zh',
  });

  final String text;
  final bool isFinal;
  final DateTime timestamp;
  final String language;
}

/// ASR 引擎接口：接收 PCM 音频块，回调增量结果。
abstract class AsrEngine {
  /// 识别结果的流（含 partial 与 final，通过 [AsrResult.isFinal] 区分）。
  Stream<AsrResult> get results;

  /// 准备引擎（加载模型等）。
  Future<void> init();

  /// 切换语言/模型。默认空实现。
  void setLanguage(String lang) {}

  /// 喂入一块 PCM 16bit 单声道音频。
  void acceptAudio(List<int> pcmChunk);

  /// 结束当前流（通知引擎 flush 残留 partial → final）。
  Future<void> finish();

  /// 关闭释放资源。
  Future<void> dispose();
}

/// 由平台识别服务自己持有麦克风的 ASR 后端。
///
/// 这类后端不接收 Flutter 的 PCM 流；会话控制器只负责在取得麦克风权限后
/// 启动它，并继续消费统一的 [AsrEngine.results]。
abstract interface class ExternalAudioAsrEngine {
  Future<void> startListening();
}

/// 可被协调器主动切段的流式识别器。
///
/// 课堂里经常会连续讲话而长期没有静音 endpoint。协调器在保存当前 partial
/// 以后调用此方法，让识别器从一个有界的新 utterance 继续，避免内部上下文
/// 随整节课无限增长。不能主动切段的实现无需实现此接口。
abstract interface class ResettableAsrSegment {
  void resetCurrentSegment();
}

/// A coordinator waits until both workers consumed the same audio block.
abstract interface class AcknowledgedAudioAsrEngine {
  Future<void> acceptAudioAndWait(List<int> pcmChunk);
}

/// 通用 ASR 事件汇聚器：把 partial/final 转发给订阅者。
class AsrStreamController {
  AsrStreamController() : _controller = StreamController<AsrResult>.broadcast();
  final StreamController<AsrResult> _controller;

  Stream<AsrResult> get stream => _controller.stream;

  void add(AsrResult r) => _controller.add(r);
  void addError(Object e) => _controller.addError(e);
  Future<void> close() => _controller.close();
}
