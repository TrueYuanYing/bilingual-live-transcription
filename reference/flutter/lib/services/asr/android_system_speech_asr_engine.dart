import 'dart:async';

import 'package:flutter/services.dart';

import 'asr_engine.dart';

/// Android 系统 SpeechRecognizer 适配器。
///
/// 这是一个显式可选后端：系统识别服务可能使用网络，也可能受设备厂商、
/// 已安装语音包和系统权限影响。它不和 Sherpa 同时抢占麦克风，失败时由
/// 会话层直接报告启动失败，避免用户误以为仍在使用本地模型。
class AndroidSystemSpeechAsrEngine
    implements AsrEngine, ExternalAudioAsrEngine {
  AndroidSystemSpeechAsrEngine({String language = 'zh'})
      : language = language == 'en' ? 'en' : 'zh';

  static const _methods =
      MethodChannel('com.classmate.classmate/system_speech');
  static const _events =
      EventChannel('com.classmate.classmate/system_speech_events');

  final AsrStreamController _results = AsrStreamController();
  StreamSubscription<dynamic>? _subscription;
  String language;
  bool _initialized = false;

  @override
  Stream<AsrResult> get results => _results.stream;

  @override
  Future<void> init() async {
    final available = await _methods.invokeMethod<bool>('isAvailable') ?? false;
    if (!available) {
      throw StateError('当前设备没有可用的 Android 系统语音识别服务');
    }
    _subscription ??= _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final text = event['text'] as String? ?? '';
        if (text.trim().isEmpty) return;
        _results.add(AsrResult(
          text: text,
          isFinal: event['isFinal'] == true,
          timestamp: DateTime.now(),
          language: event['language'] as String? ?? language,
        ));
      },
      onError: (Object error, StackTrace stack) => _results.addError(error),
    );
    _initialized = true;
  }

  @override
  void setLanguage(String lang) {
    language = switch (lang) {
      'en' => 'en',
      _ => 'zh',
    };
  }

  @override
  Future<void> startListening() async {
    if (!_initialized) await init();
    await _methods.invokeMethod<void>('start', {'language': language});
  }

  @override
  void acceptAudio(List<int> pcmChunk) {
    // 系统 SpeechRecognizer 自己采集麦克风，Flutter PCM 不应重复喂入。
  }

  @override
  Future<void> finish() async {
    try {
      await _methods.invokeMethod<void>('finish');
      // 给系统识别服务一个事件循环时间派发最后的 onResults。
      await Future<void>.delayed(const Duration(milliseconds: 450));
    } on MissingPluginException {
      // 非 Android 平台不会使用该后端；保持 dispose/stop 可调用。
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _methods.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // 非 Android 平台忽略。
    }
    await _subscription?.cancel();
    _subscription = null;
    await _results.close();
  }
}
