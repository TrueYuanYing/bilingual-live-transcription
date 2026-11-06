import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'asr_engine.dart';
import 'sherpa_native_engine.dart';

/// Keeps loading and decoding off the UI isolate. All native pointers belong
/// to the worker and are freed there, including on model changes and shutdown.
class SherpaAsrEngine
    implements AsrEngine, ResettableAsrSegment, AcknowledgedAudioAsrEngine {
  SherpaAsrEngine(
      {this.baseDir = '',
      this.language = 'zh',
      this.tokensFile = 'tokens.txt',
      this.encoderFile = 'encoder.int8.onnx',
      this.decoderFile = 'decoder.onnx',
      this.joinerFile = 'joiner.onnx'});
  String baseDir, language;
  final String tokensFile, encoderFile, decoderFile, joinerFile;
  final _events = AsrStreamController();
  final _pending = <int, Completer<void>>{};
  ReceivePort? _inbox;
  SendPort? _commands;
  Completer<SendPort>? _ready;
  Future<void>? _initializing;
  String? _loadedDir;
  int _sequence = 0, _queuedBytes = 0;
  bool _closed = false, _accepting = false, _overloaded = false;

  @override
  Stream<AsrResult> get results => _events.stream;
  String get modelDir => '$baseDir/$language';
  String? get loadedModelDirectory => _loadedDir;
  bool get isModelLoaded => _commands != null && _loadedDir == modelDir;
  @override
  void setLanguage(String lang) =>
      language = {'en', 'auto'}.contains(lang) ? lang : 'zh';

  @override
  Future<void> init() {
    if (_closed) return Future.error(StateError('识别引擎已关闭'));
    return _initializing ??=
        _initialize().whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
    _accepting = false;
    if (_commands == null) {
      _ready = Completer<SendPort>();
      _inbox = ReceivePort();
      _inbox!.listen(_receive);
      try {
        await Isolate.spawn(_sherpaWorker, _inbox!.sendPort,
            onError: _inbox!.sendPort,
            onExit: _inbox!.sendPort,
            debugName: 'sherpa-$language');
        _commands = await _ready!.future;
      } catch (_) {
        _inbox?.close();
        _inbox = null;
        rethrow;
      }
    }
    await _request('init', {
      'dir': baseDir,
      'language': language,
      'tokens': tokensFile,
      'encoder': encoderFile,
      'decoder': decoderFile,
      'joiner': joinerFile
    });
    _loadedDir = modelDir;
    _overloaded = false;
    _accepting = !_closed;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      _ready?.complete(message);
      return;
    }
    if (message is AsrResult) {
      if (!_closed) _events.add(message);
      return;
    }
    if (message is Map) {
      if (message['audio'] is int) {
        _queuedBytes -= message['audio'] as int;
        if (message['error'] != null && !_closed) {
          _accepting = false;
          _events.addError(StateError('离线识别失败：${message['error']}'));
        }
      }
      if (message['id'] is int) {
        final pending = _pending.remove(message['id']);
        if (message['error'] == null) {
          pending?.complete();
        } else {
          pending?.completeError(StateError('${message['error']}'));
        }
      }
      return;
    }
    final error =
        StateError('离线识别工作线程已停止${message is List ? '：${message.first}' : ''}');
    if (_ready != null && !_ready!.isCompleted) _ready!.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _commands = null;
    _loadedDir = null;
    _queuedBytes = 0;
    _inbox?.close();
    _inbox = null;
    if (_accepting && !_closed) _events.addError(error);
    _accepting = false;
  }

  Future<void> _request(String command, [Object? value]) {
    if (_commands == null) return Future.error(StateError('识别模型尚未加载'));
    final id = ++_sequence, done = Completer<void>();
    _pending[id] = done;
    _commands!.send({'command': command, 'id': id, 'value': value});
    return done.future;
  }

  @override
  void acceptAudio(List<int> pcmBytes) {
    if (!_accepting || _closed || pcmBytes.isEmpty) return;
    // Three seconds maximum. Report overload instead of silently dropping
    // words or allowing the mailbox to grow until Android kills the app.
    if (_queuedBytes + pcmBytes.length > 16000 * 2 * 3) {
      _accepting = false;
      if (!_overloaded) {
        _overloaded = true;
        _events.addError(StateError('设备暂时无法实时处理语音，已保存当前听写；请选单一语种或系统识别后重试'));
      }
      return;
    }
    final bytes = Uint8List.fromList(pcmBytes);
    _queuedBytes += bytes.length;
    _commands!.send({
      'command': 'audio',
      'value': TransferableTypedData.fromList([bytes]),
      'length': bytes.length
    });
  }

  @override
  Future<void> acceptAudioAndWait(List<int> pcmBytes) async {
    if (!_accepting || _closed || pcmBytes.isEmpty) return;
    final bytes = Uint8List.fromList(pcmBytes);
    await _request('pairedAudio', TransferableTypedData.fromList([bytes]));
  }

  @override
  void resetCurrentSegment() {
    if (_commands != null && !_closed) _commands!.send({'command': 'reset'});
  }

  @override
  Future<void> finish() async {
    _accepting = false;
    if (_commands != null) await _request('finish');
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _accepting = false;
    try {
      try {
        await _initializing;
      } catch (_) {/* release failed model loads */}
      if (_commands != null) await _request('dispose');
    } finally {
      _commands = null;
      _loadedDir = null;
      _inbox?.close();
      _inbox = null;
      await _events.close();
    }
  }
}

Future<void> _sherpaWorker(SendPort output) async {
  final commands = ReceivePort();
  output.send(commands.sendPort);
  SherpaNativeEngine? engine;
  StreamSubscription<AsrResult>? subscription;
  String? configuration;
  try {
    await for (final raw in commands) {
      final message = raw as Map;
      final command = message['command'];
      Object? error;
      try {
        switch (command) {
          case 'init':
            final v = message['value'] as Map;
            final nextConfiguration = v.toString();
            if (configuration != nextConfiguration) {
              await subscription?.cancel();
              await engine?.dispose();
              engine = SherpaNativeEngine(
                  baseDir: v['dir'],
                  language: v['language'],
                  tokensFile: v['tokens'],
                  encoderFile: v['encoder'],
                  decoderFile: v['decoder'],
                  joinerFile: v['joiner']);
              subscription = engine.results.listen(output.send);
              configuration = nextConfiguration;
            }
            await engine!.init();
          case 'audio':
          case 'pairedAudio':
            final bytes = (message['value'] as TransferableTypedData)
                .materialize()
                .asUint8List();
            engine?.acceptAudio(bytes);
          case 'reset':
            engine?.resetCurrentSegment();
          case 'finish':
            await engine?.finish();
          case 'dispose':
            await subscription?.cancel();
            subscription = null;
            await engine?.dispose();
            engine = null;
        }
        // Flush final/partial events before acknowledging finish to the host.
        await Future<void>.delayed(Duration.zero);
      } catch (e) {
        error = e.toString();
      }
      if (command == 'audio') {
        output.send({'audio': message['length'], 'error': error});
      } else if (message['id'] != null) {
        output.send({'id': message['id'], 'error': error});
      }
      if (command == 'dispose') break;
    }
  } finally {
    await subscription?.cancel();
    await engine?.dispose();
    commands.close();
  }
}
