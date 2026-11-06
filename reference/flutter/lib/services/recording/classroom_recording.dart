import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/class_session.dart';
import '../asr/asr_engine.dart';
import '../asr/live_session_controller.dart';

class RecordingClip {
  RecordingClip.fromMap(Map<Object?, Object?> map)
      : id = map['id'] as String,
        session = ClassSession.fromJson(
            jsonDecode(map['sessionJson'] as String) as Map<String, dynamic>),
        startedAt =
            DateTime.fromMillisecondsSinceEpoch(map['startedAt'] as int),
        duration = Duration(milliseconds: map['durationMs'] as int),
        bytes = map['bytes'] as int,
        format = map['format'] as String,
        complete = map['complete'] == true {
    session.endedAt = startedAt.add(duration);
  }

  final String id;
  final ClassSession session;
  final DateTime startedAt;
  final Duration duration;
  final int bytes;
  final String format;
  final bool complete;
}

/// Optional PCM consumer. It never owns a microphone or modifies ASR input.
class ClassroomRecording extends ChangeNotifier {
  // 16 kHz mono PCM16: eight seconds, bounded independently of the ASR stream.
  static const _maxPendingBytes = 256000;
  static const _packetBytes =
      32000; // Keep the native bridge's one-second limit.
  Map<String, String>? noteOwner;
  ClassroomRecording({
    this.channel = const MethodChannel('com.iko.study/classroom_recording'),
  }) {
    ready = _load();
  }

  final MethodChannel channel;
  late final Future<void> ready;
  SharedPreferences? _prefs;
  LiveSessionController? _live;
  StreamSubscription<LiveSessionState>? _states;
  StreamSubscription<Uint8List>? _pcm;
  Timer? _flushTimer, _displayTimer;
  Future<void> _operations = Future.value();
  _RecordingRun? _run;
  bool _disposed = false;
  bool _wasListening = false;
  String? _blockedSession;
  bool enabled = false;
  int bitrate = 12000;
  String? error;
  List<RecordingClip> clips = [];

  bool get recording => _run != null;
  bool get listening =>
      _live?.current.isRunning == true ||
      (_live?.activeSession != null && _live!.activeSession!.endedAt == null);
  bool get available =>
      _live?.recordingOnly == true || _live?.asr is! ExternalAudioAsrEngine;
  Duration get duration => Duration(milliseconds: _run?.durationMs ?? 0);
  int get bytes => _run?.bytes ?? 0;
  String get format => _run?.format ?? 'Opus';

  // A test/diagnostic boundary; never awaited by ASR.
  Future<void> get settled async {
    await Future<void>.delayed(Duration.zero);
    await _operations;
    await _run?.flight;
    await _operations;
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    enabled = _prefs!.getBool('classroom_recording_enabled') ?? false;
    final saved = _prefs!.getInt('classroom_recording_bitrate');
    bitrate = const [8000, 12000, 16000].contains(saved) ? saved! : 12000;
    if (_prefs!.getBool('recording_compression_v2') != true) {
      bitrate = saved == null
          ? 12000
          : bitrate == 12000
              ? 8000
              : 12000;
      await _prefs!.setInt('classroom_recording_bitrate', bitrate);
      await _prefs!.setBool('recording_compression_v2', true);
    }
    await refresh();
    if (!_disposed) {
      _sync();
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    try {
      final raw = await _bounded(channel.invokeListMethod<Object?>('list'));
      final loaded = <RecordingClip>[];
      for (final row in raw ?? []) {
        try {
          loaded.add(RecordingClip.fromMap(row as Map<Object?, Object?>));
        } catch (_) {/* A damaged sidecar cannot hide other recordings. */}
      }
      loaded.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      if (!_disposed) {
        clips = loaded;
        notifyListeners();
      }
    } on PlatformException catch (_) {
      // Listing cannot interfere with capture. Enabling will show a useful error.
    } on MissingPluginException catch (_) {
      // The Android bridge is optional on non-Android test surfaces.
    } on TimeoutException catch (_) {
      // A slow file scan must not prevent capture or freeze the operation queue.
    }
  }

  void bind(LiveSessionController live) {
    if (identical(_live, live)) return;
    unbind();
    _live = live;
    _states = live.state.listen((_) => _sync());
    scheduleMicrotask(() {
      if (!_disposed) {
        _sync();
        _notify(); // Engine changes must refresh the system-speech availability hint.
      }
    });
  }

  void unbind([LiveSessionController? expected]) {
    if (expected != null && !identical(expected, _live)) return;
    unawaited(_states?.cancel());
    _states = null;
    _live = null;
    _stop();
  }

  Future<void> setEnabled(bool value) async {
    await ready;
    enabled = value;
    error = null;
    _blockedSession = null;
    _sync();
    _notify();
    await _prefs!.setBool('classroom_recording_enabled', value);
  }

  Future<void> share(List<String> clipIds,
      {String? target, bool asFile = true}) async {
    if (listening || recording) throw StateError('请先结束录音，再分享。');
    await channel.invokeMethod<void>(
        'share', {'clipIds': clipIds, 'target': target, 'asFile': asFile});
  }

  Future<void> setBitrate(int value) async {
    await ready;
    if (recording) return; // Never restart a live encoder for a UI preference.
    bitrate = const [8000, 12000, 16000].contains(value) ? value : 12000;
    _notify();
    await _prefs!.setInt('classroom_recording_bitrate', bitrate);
  }

  void _sync() {
    final live = _live;
    if (listening && !_wasListening) {
      unawaited(stopPlayback().catchError((Object _) {}));
    }
    _wasListening = listening;
    final session = live?.activeSession;
    if (live?.current.isRunning != true || !available || !enabled) {
      _stop();
      return;
    }
    if (session == null ||
        _run?.sessionId == session.id ||
        _blockedSession == session.id) {
      return;
    }
    _stop();
    final run = _RecordingRun(
        'rec_${DateTime.now().microsecondsSinceEpoch}', session.id);
    final owner = live!.recordingOnly ? noteOwner : null;
    _run = run;
    error = null;
    // A cold encoder or brief storage stall must not abandon the whole class.
    _pcm = live.audio.stream.listen((chunk) {
      if (!identical(_run, run)) return;
      if (run.pendingBytes + chunk.length > _maxPendingBytes) {
        _fail(run, '录音保存跟不上，已停止录音；听写继续。可关闭录音后重新开启。');
        return;
      }
      run.pending.add(Uint8List.fromList(chunk));
      run.pendingBytes += chunk.length;
    }, onError: (Object _) => _fail(run, '录音音频暂不可用，听写状态请查看上方提示。'));
    _operations = _operations.then((_) async {
      try {
        final data =
            await _bounded(channel.invokeMapMethod<String, Object?>('start', {
          'id': run.id,
          'sessionJson': jsonEncode(session.toJson()),
          'bitrate': bitrate,
          'noteOwner': owner == null ? null : jsonEncode(owner),
        }));
        run.open = true;
        run.format = data?['format'] as String? ?? 'Opus';
        _flush(run);
        _notify();
      } catch (e) {
        _fail(run, _message(e));
      }
    });
    _flushTimer =
        Timer.periodic(const Duration(milliseconds: 100), (_) => _flush(run));
    _displayTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _notify());
    _notify();
  }

  void _flush(_RecordingRun run) {
    if (!run.open ||
        run.flight != null ||
        run.pendingBytes == 0 ||
        run.failed) {
      return;
    }
    final buffer = Uint8List(run.pendingBytes.clamp(0, _packetBytes));
    var written = 0;
    while (written < buffer.length) {
      final chunk = run.pending.first;
      final count =
          (chunk.length - run.pendingOffset).clamp(0, buffer.length - written);
      buffer.setRange(written, written + count, chunk, run.pendingOffset);
      written += count;
      run.pendingOffset += count;
      if (run.pendingOffset == chunk.length) {
        run.pending.removeFirst();
        run.pendingOffset = 0;
      }
    }
    run.pendingBytes -= written;
    run.flight = () async {
      try {
        final data =
            await _bounded(channel.invokeMapMethod<String, Object?>('append', {
          'id': run.id,
          'pcm': buffer,
        }));
        run.durationMs = data?['durationMs'] as int? ?? run.durationMs;
        run.bytes = data?['bytes'] as int? ?? run.bytes;
      } catch (e) {
        _fail(run, _message(e));
      } finally {
        run.flight = null;
      }
    }();
  }

  void _stop() {
    final run = _run;
    if (run == null) return;
    _run =
        null; // Detach immediately. A new session cannot append to the old one.
    unawaited(_pcm?.cancel());
    _pcm = null;
    _flushTimer?.cancel();
    _displayTimer?.cancel();
    _operations = _operations.then((_) async {
      await run.flight;
      while (run.open && !run.failed && run.pendingBytes > 0) {
        _flush(run);
        await run.flight;
      }
      try {
        // Also clean up a start whose reply timed out but may have opened natively.
        await _bounded(channel.invokeMethod<void>('stop', {'id': run.id}));
      } catch (e) {
        error = _message(e);
      }
      await refresh();
    });
    _notify();
  }

  void _fail(_RecordingRun run, String message) {
    if (run.failed) return;
    run.failed = true;
    run.pending.clear();
    run.pendingOffset = 0;
    run.pendingBytes = 0;
    if (_run == null) {
      error = message; // Also report a failure while draining the tail.
    }
    if (identical(_run, run)) {
      error = message;
      _blockedSession = run.sessionId;
      _stop();
    }
  }

  Future<void> deleteSession(String sessionId) async {
    if (_run?.sessionId == sessionId) throw StateError('请先停止这节课的录音');
    await settled;
    await channel.invokeMethod<void>('delete', {'sessionId': sessionId});
    await refresh();
  }

  Future<void> deleteClips(List<String> ids) async {
    if (listening || recording) throw StateError('请结束听写或录音后再删除音频');
    await settled;
    await channel.invokeMethod<void>('deleteClips', {'clipIds': ids});
    await refresh();
  }

  Future<void> play(String clipId) async {
    if (listening) throw StateError('请先结束听写，再回放录音');
    await channel.invokeMethod<void>('play', {'clipId': clipId});
  }

  Future<void> pause() => channel.invokeMethod<void>('pause');
  Future<void> stopPlayback() => channel.invokeMethod<void>('stopPlayback');
  Future<void> seek(int milliseconds) =>
      channel.invokeMethod<void>('seek', {'positionMs': milliseconds});
  Future<Map<String, Object?>> player() async =>
      await channel.invokeMapMethod<String, Object?>('player') ?? {};
  Future<bool> export(String clipId) async =>
      await channel.invokeMethod<bool>('export', {'clipId': clipId}) ?? false;

  String _message(Object e) => e is PlatformException
      ? '${e.message ?? '无法保存录音'}；听写继续。'
      : '录音保存暂不可用，听写继续。';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // Own the timeout timers so disposal cancels them, including a scan started
  // while the page/provider was already being removed.
  final _waits = <Timer, void Function()>{};
  Future<T> _bounded<T>(Future<T> operation) {
    if (_disposed) return operation;
    final result = Completer<T>();
    final timer = Timer(const Duration(seconds: 10), () {
      if (!result.isCompleted) result.completeError(TimeoutException('录音保存超时'));
    });
    _waits[timer] = () {
      if (!result.isCompleted) {
        result.completeError(TimeoutException('录音服务已关闭'));
      }
    };
    operation.then((value) {
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object e, StackTrace stack) {
      if (!result.isCompleted) result.completeError(e, stack);
    });
    return result.future.whenComplete(() {
      timer.cancel();
      _waits.remove(timer);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unbind();
    for (final wait in _waits.entries.toList()) {
      wait.key.cancel();
      wait.value();
    }
    unawaited(stopPlayback().catchError((Object _) {}));
    super.dispose();
  }
}

class _RecordingRun {
  _RecordingRun(this.id, this.sessionId);
  final String id, sessionId;
  final pending = ListQueue<Uint8List>();
  int pendingBytes = 0, pendingOffset = 0, durationMs = 0, bytes = 0;
  String format = 'Opus';
  bool open = false, failed = false;
  Future<void>? flight;
}
