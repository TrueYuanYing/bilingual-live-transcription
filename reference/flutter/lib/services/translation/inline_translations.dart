import 'dart:async';
import 'dart:collection';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../ai/ai_answer_service.dart';
import '../asr/mixed_language_text.dart';

/// A final-text sidecar. Never feeds translated text back into recognition.
class InlineTranslations extends ChangeNotifier {
  InlineTranslations({required this.translate});
  final Future<String> Function(String text, CancelToken token) translate;
  final _queue = Queue<String>();
  final _requested = <String>{};
  Map<String, String> _translations = const {};
  Map<String, String> get translations => _translations;
  final _failures = <String, String>{};
  final _superseded = <String>{};
  String? _queueError;
  String? get error => !_enabled
      ? null
      : _queueError ??
          (_failures.isEmpty
              ? null
              : '${_failures.length} 段英文尚未翻译：${_failures.values.first} 原文听写继续。');
  bool get hasFailures => _failures.isNotEmpty;
  bool _manualRetry = false;
  bool _enabled = false;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  CancelToken? _request;
  String? _requestSource;

  void _cancel() {
    _generation++;
    _request?.cancel('translation stopped');
    _request = null;
    _requestSource = null;
    _manualRetry = false;
    _queue.clear();
    _requested
      ..clear()
      ..addAll(_translations.keys);
  }

  void startSession() {
    _cancel();
    _running = true;
    _translations = const {};
    _requested.clear();
    _failures.clear();
    _superseded.clear();
    _queueError = null;
    notifyListeners();
  }

  void stopSession() {
    for (final source in [
      if (_requestSource != null) _requestSource!,
      ..._queue
    ]) {
      if (!_translations.containsKey(source) && !_superseded.contains(source)) {
        _failures.putIfAbsent(source, () => '听写结束时尚未完成，可手动补译。');
      }
    }
    _running = false;
    _cancel();
    notifyListeners();
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) _cancel();
    notifyListeners();
  }

  /// Explicit retry also works after recording stops; never restarts the mic.
  void retryFailed() {
    if (!_enabled || _disposed || _failures.isEmpty) return;
    _manualRetry = true;
    for (final source in _failures.keys) {
      if (_requested.add(source)) _queue.add(source);
    }
    if (_request == null && _queue.isNotEmpty) unawaited(_drain());
  }

  static Iterable<String> _englishSources(String text) sync* {
    for (final span in MixedLanguageText.spans(text)) {
      if (span.language != TranscriptSpanLanguage.english) continue;
      final source = span.text.trim().replaceFirst(RegExp(r'[，。！？；：、]+$'), '');
      if (MixedLanguageText.hasEnglish(source)) yield source;
    }
  }

  void replaceFinal(String original, String corrected) {
    if (!_enabled || !_running || _disposed) return;
    final next = _englishSources(corrected).toSet();
    for (final source in _englishSources(original)) {
      if (next.contains(source)) continue;
      _superseded.add(source);
      _failures.remove(source);
      if (_queue.remove(source)) _requested.remove(source);
    }
    addFinal(corrected);
    notifyListeners();
  }

  void addFinal(String text) {
    if (!_enabled || !_running || _disposed) return;
    for (final source in _englishSources(text)) {
      _superseded.remove(source);
      if (_requested.contains(source)) continue;
      // ponytail: bounded per-class backlog; never let slow cloud calls stall ASR.
      if (_queue.length >= 128) {
        _queueError = '英文翻译暂时积压，原文听写继续。';
        notifyListeners();
        break;
      }
      _requested.add(source);
      _queue.add(source);
    }
    if (_request == null && _queue.isNotEmpty) unawaited(_drain());
  }

  Future<void> _drain() async {
    final generation = _generation;
    while (!_disposed &&
        _enabled &&
        (_running || _manualRetry) &&
        generation == _generation &&
        _queue.isNotEmpty) {
      final source = _queue.removeFirst();
      final token = CancelToken();
      _request = token;
      _requestSource = source;
      try {
        final result = (await translate(source, token)).trim();
        if (_disposed || generation != _generation || token.isCancelled) return;
        if (result.isEmpty) {
          throw StateError(AiAnswerService.emptySummaryMessage);
        }
        _translations = Map.unmodifiable({..._translations, source: result});
        _failures.remove(source);
        _queueError = null;
        notifyListeners();
      } catch (failure) {
        if (_disposed || generation != _generation || token.isCancelled) return;
        _requested.remove(source);
        if (!_superseded.contains(source)) {
          _failures[source] = AiAnswerService.friendlyError(failure);
        }
        notifyListeners();
      } finally {
        if (generation == _generation) {
          _request = null;
          _requestSource = null;
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    super.dispose();
  }
}
