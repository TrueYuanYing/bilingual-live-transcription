import 'dart:async';

import '../../data/models/class_session.dart';
import '../alert/alert_engine.dart';
import '../asr/asr_engine.dart';
import '../asr/mixed_language_asr_engine.dart';
import '../asr/mixed_language_text.dart';
import '../asr/mixed_language_terms.dart';
import '../asr/sherpa_asr_engine.dart';
import '../asr/streaming_hypothesis_tracker.dart';
import 'transcript_refiner.dart';
import '../audio/record_audio_capture.dart';

/// 实时听写会话的运行时状态，供 UI 订阅。
class LiveSessionState {
  LiveSessionState({
    this.isRunning = false,
    this.transcript = '',
    this.livePartial = '',
    this.translation = '',
    this.duration = Duration.zero,
    this.alerts = const [],
    this.language = 'zh',
    this.error,
  });

  final bool isRunning;
  final String transcript;
  final String livePartial;

  /// 译文（外语课的实时翻译累积）。
  final String translation;

  final Duration duration;
  final List<AlertEvent> alerts;
  final String language;
  final String? error;

  LiveSessionState copyWith({
    bool? isRunning,
    String? transcript,
    String? livePartial,
    String? translation,
    Duration? duration,
    List<AlertEvent>? alerts,
    String? language,
    String? error,
  }) =>
      LiveSessionState(
        isRunning: isRunning ?? this.isRunning,
        transcript: transcript ?? this.transcript,
        livePartial: livePartial ?? this.livePartial,
        translation: translation ?? this.translation,
        duration: duration ?? this.duration,
        alerts: alerts ?? this.alerts,
        language: language ?? this.language,
        error: error ?? this.error,
      );
}

/// 协调音频采集 + ASR + 预警引擎，产出 [LiveSessionState] 流。
/// 纯 Dart，不依赖 Flutter，便于测试；弹窗、悬浮窗由 UI 层消费流触发。
class LiveSessionController {
  LiveSessionController({
    required this.audio,
    required this.asr,
    required this.alertEngine,
    this.alertEngineResolver,
    this.onSessionComplete,
    this.onSessionCheckpoint,
    this.translator,
    this.transcriptEnhancer,
    this.shouldEnhanceTranscript,
    this.shouldRefineTranscript,
    this.shouldAlert,
    this.preferWeakSpeech,
    this.onCaptureStopped,
    this.now = DateTime.now,
    this.segmentCommitInterval = const Duration(seconds: 5),
    this.partialUpdateInterval = const Duration(milliseconds: 80),
  });

  final AudioCapture audio;
  final AsrEngine asr;
  AlertEngine alertEngine;

  /// 在真正开始听写时刷新一次身份/关键词规则，避免 App 启动时异步设置
  /// 尚未加载完成，控制器长期持有空身份规则而漏掉本人红色预警。
  final Future<AlertEngine> Function()? alertEngineResolver;

  /// 会话结束时的回调（用于把完整记录持久化）。
  final void Function(ClassSession session)? onSessionComplete;

  /// 运行中定期提供课堂快照。回调收到的是独立副本，可异步落盘，不会被后续
  /// 识别结果继续修改。
  final void Function(ClassSession session)? onSessionCheckpoint;

  /// 翻译回调（外语课实时翻译，注入 AiAnswerService.translate）。
  final Future<String> Function(String text)? translator;

  /// 可选的最终句纠错器；是否启用由调用方显式控制。
  final Future<String> Function(String text)? transcriptEnhancer;
  final bool Function()? shouldEnhanceTranscript;

  /// 本地分句/分段开关；关闭时保持原始正文拼接行为。
  final bool Function()? shouldRefineTranscript;

  /// 预警总开关，由设置层注入；默认开启，便于纯 Dart 使用和测试。
  final bool Function()? shouldAlert;
  final bool Function()? preferWeakSpeech;
  final Future<void> Function()? onCaptureStopped;

  /// 可注入时钟，便于稳定测试预警时间窗口。
  final DateTime Function() now;

  /// 最长临时字幕窗口。持续讲话时定期保存可由 final 修订的正文快照，
  /// 不重置底层 decoder，避免切断正在说的词。
  final Duration segmentCommitInterval;

  /// partial 只用于视觉反馈；合并同一帧内的快速变化并限制到约 12.5Hz，避免
  /// 长时间听写时 UI rebuild / 自动滚动队列追不上音频。
  final Duration partialUpdateInterval;

  /// 模型根目录（sherpa_models）。start 时按语言拼子目录。
  String baseDir = '';

  /// 异步解析模型根目录的函数（Provider 注入）。
  Future<String> Function()? baseDirResolver;

  /// 获取当前识别语种（'zh'/'en'）。
  String Function()? getLanguage;

  final _state = StreamController<LiveSessionState>.broadcast();
  LiveSessionState _current = LiveSessionState();
  List<AlertEvent> _events = [];
  List<String> _completedAlertPrefixes = [];
  bool _completedAwaitingFinal = false;
  String _completedUtteranceText = '';
  bool _running = false;
  bool _recordingOnly = false;
  bool get recordingOnly => _recordingOnly;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _disposed = false;
  String _sessionLanguage = 'zh';

  final List<StreamSubscription> _subs = [];
  final SegmentedTranscriptBuffer _finalBuffer = SegmentedTranscriptBuffer();
  final StreamingHypothesisTracker _hypothesis = StreamingHypothesisTracker();
  int? _provisionalSegmentIndex;
  final List<_AlertFragment> _alertFragments = [];
  final StringBuilder _translationBuffer = StringBuilder();
  Timer? _timer;
  Timer? _segmentCommitTimer;
  Timer? _partialUpdateTimer;
  AsrResult? _pendingPartial;
  DateTime? _lastPartialUpdateAt;
  DateTime? _startedAt;

  ClassSession? _activeSession;

  bool _translationRunning = false;
  _TranslationRequest? _pendingTranslation;

  bool _enhancementRunning = false;
  _EnhancementRequest? _pendingEnhancement;
  int _sessionGeneration = 0;

  Stream<LiveSessionState> get state => _state.stream;
  LiveSessionState get current => _current;

  /// 当前进行中的课堂会话。
  ClassSession? get activeSession => _activeSession;

  /// 异步解析模型根目录（若无外部注入 baseDir）。
  Future<String> _resolveBaseDir() async {
    if (baseDirResolver != null) return baseDirResolver!();
    return baseDir;
  }

  /// 开始一次实时听写。
  Future<void> start({String courseName = '自由课堂'}) {
    if (_disposed) return Future.error(StateError('听写会话已关闭'));
    return _starting ??=
        _startAfterStop(courseName).whenComplete(() => _starting = null);
  }

  /// Reuses the classroom microphone and persistence, without initializing ASR.
  Future<void> startRecordingOnly() {
    if (_disposed) return Future.error(StateError('课堂会话已关闭'));
    return _starting ??= _startAfterStop('笔记录音', recordingOnly: true)
        .whenComplete(() => _starting = null);
  }

  Future<void> _startAfterStop(String courseName,
      {bool recordingOnly = false}) async {
    await _stopping;
    if (_disposed) return;
    try {
      await _start(courseName: courseName, recordingOnly: recordingOnly);
    } catch (_) {
      await _stop();
      rethrow;
    }
  }

  Future<void> _start(
      {required String courseName, bool recordingOnly = false}) async {
    if (_running) return;
    _recordingOnly = recordingOnly;
    if (!recordingOnly) {
      final resolveAlertEngine = alertEngineResolver;
      if (resolveAlertEngine != null) {
        try {
          alertEngine = await resolveAlertEngine();
        } catch (_) {
          // 设置/关键词加载异常时保留已有规则，听写主流程仍可继续。
        }
      }
      final selected = getLanguage?.call();
      final selectedLanguage =
          selected == 'en' || selected == 'auto' ? selected! : 'zh';
      _sessionLanguage = selectedLanguage;
      // 同步模型目录与语种给 ASR 引擎，确保加载对应模型。
      final dir = baseDir.isNotEmpty ? baseDir : await _resolveBaseDir();
      if (dir.isNotEmpty) {
        final engine = asr;
        if (engine is SherpaAsrEngine) {
          engine.baseDir = dir;
          engine.setLanguage(selectedLanguage);
        } else if (engine is MixedLanguageAsrEngine) {
          engine.setBaseDir(dir);
        }
      }
      await asr.init();
    }

    _startedAt = now();
    _events = [];
    _completedAlertPrefixes = [];
    _completedAwaitingFinal = false;
    _finalBuffer.clear();
    _hypothesis.reset();
    _provisionalSegmentIndex = null;
    _alertFragments.clear();
    _translationBuffer.clear();
    _translationRunning = false;
    _pendingTranslation = null;
    _enhancementRunning = false;
    _pendingEnhancement = null;
    _sessionGeneration++;
    _partialUpdateTimer?.cancel();
    _partialUpdateTimer = null;
    _pendingPartial = null;
    _lastPartialUpdateAt = null;
    _running = true;
    _activeSession = ClassSession(
      id: 'sess_${_startedAt!.millisecondsSinceEpoch}',
      title: courseName,
      courseName: courseName,
      startedAt: _startedAt!,
      language: _sessionLanguage,
    );
    _current = LiveSessionState(language: _sessionLanguage);

    if (!recordingOnly) {
      _subs.add(asr.results.listen(_onAsrResult, onError: _onRuntimeError));
    }
    final externalAudio = !recordingOnly && asr is ExternalAudioAsrEngine;
    if (externalAudio) {
      final granted = await audio.requestPermission();
      if (!granted) throw StateError('麦克风权限未授予');
      await (asr as ExternalAudioAsrEngine).startListening();
    } else {
      _subs.add(audio.stream.listen(recordingOnly ? (_) {} : _onAudioChunk,
          onError: _onRuntimeError));
      await audio.start(AudioConfig(
        sampleRate: 16000,
        numChannels: 1,
        noiseSuppress: !(preferWeakSpeech?.call() ?? true),
        farField: preferWeakSpeech?.call() ?? true,
      ));
    }
    _startTimer();
    _startSegmentCommitTimer();
    if (recordingOnly) _checkpointActiveSession();
    _emit();
  }

  /// 用户手动结束，或下课自动触发。
  Future<void> stop() =>
      _stopping ??= _stopAfterStart().whenComplete(() => _stopping = null);

  Future<void> _stopAfterStart() async {
    final starting = _starting;
    try {
      await starting;
    } catch (_) {/* failed startup already rolled back */}
    await _stop();
  }

  Future<void> _stop() async {
    if (!_running) return;
    _segmentCommitTimer?.cancel();
    _segmentCommitTimer = null;
    _flushPendingPartial();
    _commitCurrentPartial();
    _checkpointActiveSession();
    _running = false;
    _pendingEnhancement = null;
    _pendingTranslation = null;
    _emit();
    if (!_recordingOnly) {
      try {
        await asr.finish().timeout(const Duration(seconds: 2));
      } catch (_) {
        // 退出必须可用；底层识别器异常或超时时保留已落盘的最新快照。
      }
    }
    // finish 的广播在下一个事件循环送达，等待最终句处理完成。
    await Future<void>.delayed(Duration.zero);
    if (_recordingOnly || asr is! ExternalAudioAsrEngine) {
      try {
        await audio.stop().timeout(const Duration(seconds: 2));
      } catch (_) {
        // 前台录音服务由 UI 同步关闭，不让插件 stop 卡死返回操作。
      }
    }
    _timer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _activeSession?.endedAt = DateTime.now();
    _checkpointActiveSession();
    // 通知外部：一条完整课堂记录已结束，可持久化。
    final s = _activeSession;
    if (s != null && (_recordingOnly || s.transcript.isNotEmpty)) {
      onSessionComplete?.call(_snapshotOf(s));
    }
    _emit();
    await onCaptureStopped?.call();
  }

  void _onAudioChunk(AudioChunk chunk) {
    if (!_running) return;
    try {
      asr.acceptAudio(chunk);
    } catch (error) {
      _onRuntimeError(error);
    }
  }

  void _onRuntimeError(Object error) {
    if (!_running) return;
    _current = _current.copyWith(error: error.toString());
    unawaited(stop());
  }

  void _onAsrResult(AsrResult r) {
    // 先做本地术语救援，再进入云端纠错或字幕/预警链路，避免同一片段
    // 在不同链路里出现 Codex/claude/中文谐音来回跳变。
    final normalizedText = MixedLanguageTerms.canonicalize(r.text);
    if (normalizedText != r.text) {
      r = AsrResult(
        text: normalizedText,
        isFinal: r.isFinal,
        timestamp: r.timestamp,
        language: r.language,
      );
    }
    final replacementIndex = r.isFinal ? _provisionalSegmentIndex : null;
    if (r.isFinal && replacementIndex != null) {
      // 周期快照不是不可变的定稿；final 可以修正整个当前 utterance。
      _hypothesis.reset();
      _provisionalSegmentIndex = null;
    } else {
      final text =
          r.isFinal ? _hypothesis.finish(r.text) : _hypothesis.observe(r.text);
      r = AsrResult(
        text: text,
        isFinal: r.isFinal,
        timestamp: r.timestamp,
        language: r.language,
      );
    }
    if (r.text.trim().isEmpty) {
      if (r.isFinal) {
        _completedAwaitingFinal = false;
        _partialUpdateTimer?.cancel();
        _partialUpdateTimer = null;
        _pendingPartial = null;
      }
      return;
    }
    if (!r.isFinal) {
      _queuePartial(r);
      return;
    }
    _partialUpdateTimer?.cancel();
    _partialUpdateTimer = null;
    _pendingPartial = null;
    final segmentIndex =
        _acceptAsrResult(r, replaceSegmentIndex: replacementIndex);
    final enhancer = transcriptEnhancer;
    if (_running &&
        r.isFinal &&
        segmentIndex != null &&
        (shouldEnhanceTranscript?.call() ?? false) &&
        enhancer != null &&
        r.text.trim().isNotEmpty) {
      _enqueueEnhancement(_EnhancementRequest(
        generation: _sessionGeneration,
        segmentIndex: segmentIndex,
        originalText: r.text,
        enhancer: enhancer,
      ));
    }
  }

  void _queuePartial(AsrResult result) {
    _pendingPartial = result;
    if (_partialUpdateTimer != null) return;
    final last = _lastPartialUpdateAt;
    final elapsed =
        last == null ? partialUpdateInterval : DateTime.now().difference(last);
    final remaining = partialUpdateInterval - elapsed;
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _partialUpdateTimer = Timer(delay, _flushPendingPartial);
  }

  void _flushPendingPartial() {
    _partialUpdateTimer?.cancel();
    _partialUpdateTimer = null;
    final pending = _pendingPartial;
    _pendingPartial = null;
    if (pending == null) return;
    _lastPartialUpdateAt = DateTime.now();
    _acceptAsrResult(pending);
  }

  int? _acceptAsrResult(AsrResult r,
      {int? replaceSegmentIndex, bool isProvisional = false}) {
    if (!r.isFinal && r.text == _current.livePartial) {
      return null;
    }
    if (_completedAwaitingFinal && _hasNewQuestionAfterCompletion(r.text)) {
      _completedAwaitingFinal = false;
    }
    // 中文主句夹带英文时保持中文主语言，原始边界交给字幕 UI 展示。
    final segmentLanguage = _sessionLanguage == 'auto'
        ? MixedLanguageText.primaryLanguage(r.text, fallback: r.language)
        : _sessionLanguage;

    if (r.isFinal) {
      // final → 追加到正文，清空 partial。
      final refined = _refineTranscriptSegment(r.text);
      final int segmentIndex;
      if (replaceSegmentIndex != null) {
        _finalBuffer.replace(replaceSegmentIndex, refined);
        segmentIndex = replaceSegmentIndex;
      } else {
        segmentIndex =
            _finalBuffer.append(refined, deduplicate: !isProvisional);
      }
      final transcript = _finalBuffer.toString();
      _activeSession?.transcript = transcript;
      _current = _current.copyWith(
        transcript: transcript,
        livePartial: '',
        language: _sessionLanguage,
      );
      // final 结果同样过一遍预警，覆盖被截断的语句。
      if (_completedAwaitingFinal) {
        // A real final closes the same utterance even when it corrects the
        // completed partial. It must not reopen a manually resolved question.
        if (!isProvisional) {
          _completedAwaitingFinal = false;
          _completedAlertPrefixes.addAll([r.text, transcript]);
          _alertFragments.clear();
        }
      } else {
        _rememberAlertFragment(r.text,
            isFinal: !isProvisional, timestamp: now());
        _scanAlerts(_alertWindow(transcript), isFinal: !isProvisional);
      }
      // 句中出现英文也翻译，覆盖中文课堂夹带英文术语/例句的场景。
      // 中文主句里出现 Codex / API 等术语时只高亮，不把整句误送去翻译；
      // 英语课或基本全英文片段才进入翻译链路。
      if (!isProvisional &&
          (_sessionLanguage == 'en' ||
              (segmentLanguage == 'en' &&
                  !MixedLanguageText.hasChinese(r.text)))) {
        _translateSegment(r.text);
      }
      _emit();
      return segmentIndex;
    } else {
      // partial → 仅更新实时字幕。
      _current = _current.copyWith(
        livePartial: r.text,
        language: _sessionLanguage,
      );
    }
    // partial 也做实时预警（点名刚出口就弹）。
    if (!r.isFinal && r.text.isNotEmpty && !_completedAwaitingFinal) {
      _rememberAlertFragment(r.text, isFinal: false, timestamp: now());
      _scanAlerts(_alertWindow('${_finalBuffer.toString()}${r.text}'),
          isFinal: false);
    }
    _emit();
    return null;
  }

  /// 云端只做“事后润色”：本地 final 已经先进入白色正文。队列最多保留
  /// 一个正在处理和一个最新待处理片段，网络慢时丢弃过时的纠错任务而不是
  /// 让整节课的 UI、退出流程和后续字幕一起排队。
  void _enqueueEnhancement(_EnhancementRequest request) {
    if (_enhancementRunning) {
      _pendingEnhancement = request;
      return;
    }
    unawaited(_runEnhancement(request));
  }

  Future<void> _runEnhancement(_EnhancementRequest request) async {
    _enhancementRunning = true;
    try {
      var corrected = (await request
              .enhancer(request.originalText)
              .timeout(const Duration(seconds: 12)))
          .trim();
      if (shouldRefineTranscript?.call() ?? false) {
        corrected = _refineTranscriptSegment(corrected);
      }
      if (!_running ||
          request.generation != _sessionGeneration ||
          corrected.isEmpty ||
          corrected == request.originalText) {
        return;
      }
      if (_finalBuffer.replace(request.segmentIndex, corrected)) {
        final transcript = _finalBuffer.toString();
        _activeSession?.transcript = transcript;
        _current = _current.copyWith(transcript: transcript);
        _emit();
      }
    } catch (_) {
      // 超时或纠错失败时保留已经显示的本地原文。
    } finally {
      if (request.generation == _sessionGeneration) {
        _enhancementRunning = false;
        final next = _pendingEnhancement;
        _pendingEnhancement = null;
        if (next != null && _running && next.generation == _sessionGeneration) {
          unawaited(_runEnhancement(next));
        }
      }
    }
  }

  /// 简单语言检测：中文字符占比 < 15% 判为外语（en）。
  static String detectTranscriptLanguage(String text) {
    if (text.isEmpty) return 'zh';
    var chinese = 0;
    for (final ch in text.runes) {
      if ((ch >= 0x4E00 && ch <= 0x9FFF) || (ch >= 0x3400 && ch <= 0x4DBF)) {
        chinese++;
      }
    }
    final ratio = chinese / text.length;
    return ratio < 0.15 ? 'en' : 'zh';
  }

  /// 翻译一段外语，累积到译文。
  Future<void> _translateSegment(String text) async {
    final t = translator;
    if (!_running || t == null || text.trim().isEmpty) return;
    final request = _TranslationRequest(
      generation: _sessionGeneration,
      text: text,
      translator: t,
    );
    if (_translationRunning) {
      _pendingTranslation = request;
      return;
    }
    unawaited(_runTranslation(request));
  }

  Future<void> _runTranslation(_TranslationRequest request) async {
    _translationRunning = true;
    try {
      final translated = (await request
              .translator(request.text)
              .timeout(const Duration(seconds: 12)))
          .trim();
      if (!_running ||
          request.generation != _sessionGeneration ||
          translated.isEmpty) {
        return;
      }
      _translationBuffer.write(translated);
      _translationBuffer.write('\n');
      _current = _current.copyWith(translation: _translationBuffer.toString());
      _emit();
    } catch (_) {
      // 翻译失败不影响 ASR，也不把错误文本当作字幕追加。
    } finally {
      if (request.generation == _sessionGeneration) {
        _translationRunning = false;
        final next = _pendingTranslation;
        _pendingTranslation = null;
        if (next != null && _running && next.generation == _sessionGeneration) {
          unawaited(_runTranslation(next));
        }
      }
    }
  }

  void completeQuestion(AlertEvent event, {String? answer}) {
    _completedUtteranceText = _current.livePartial;
    _completedAwaitingFinal = _current.livePartial.trim().isNotEmpty ||
        _provisionalSegmentIndex != null ||
        _pendingPartial != null;
    _completedAlertPrefixes = [
      '${_current.transcript} ${_current.livePartial}'.trim(),
      _current.livePartial,
      _alertFragments.map((fragment) => fragment.text).join(' '),
      event.triggerText,
      event.question ?? '',
    ].where((text) => text.trim().isNotEmpty).toList();
    _alertFragments.clear();
    for (final stored in _events) {
      if (stored.timestamp == event.timestamp && stored.type == event.type) {
        stored.isCompleted = true;
        if (answer?.trim().isNotEmpty == true) stored.savedAnswer = answer;
      }
    }
    event.isCompleted = true;
    if (answer?.trim().isNotEmpty == true) event.savedAnswer = answer;
    _activeSession?.events = List.of(_events);
    _current = _current.copyWith(alerts: List.of(_events));
    _checkpointActiveSession();
    _emit();
  }

  void _scanAlerts(String text, {required bool isFinal}) {
    if (!(shouldAlert?.call() ?? true)) return;
    final hits = alertEngine.process(text, isFinal: isFinal);
    for (final hit in hits) {
      final timestamp = now();
      // 存储完整题目；同一事件必须接受后续补全，展示层自行截行。
      final incoming = AlertEvent(
        type: hit.type,
        timestamp: timestamp,
        triggerText: hit.triggerText,
        question: hit.question,
        confidence: hit.confidence,
        isFinal: isFinal,
      );
      _events = AlertEventMerger.merge([..._events, incoming]);
      _activeSession?.events = List.of(_events);
      _current = _current.copyWith(alerts: List.of(_events));
    }
  }

  /// ASR 可能将“谷俊 / 哲你回答”拆成相邻结果；保留最近窗口让姓名、
  /// 学号跨片段仍然可以命中，同时限制长度避免每次扫描整节课内容。
  String _alertWindow(String text) {
    final cutoff = now().subtract(const Duration(seconds: 15));
    _alertFragments
        .removeWhere((fragment) => fragment.timestamp.isBefore(cutoff));
    if (_alertFragments.isNotEmpty) {
      return _alertFragments.map((fragment) => fragment.text).join(' ');
    }
    text = _afterCompletedQuestion(text);
    const maxLength = 140;
    if (text.length <= maxLength) return text;
    return text.substring(text.length - maxLength);
  }

  bool _hasNewQuestionAfterCompletion(String text) {
    final tail = _afterCompletedQuestion(text.trim());
    if (tail.isEmpty) return false;
    final newQuestion = RegExp(
        r'^(?:现在|接下来|下一个|新的问题|另外|其次|第[二三四五六]个)|'
        r'^(?:请(?:问|解释|说明)?)?(?:为什么|为何|如何|怎么|什么|哪|是否|能否|计算|证明|求)|'
        r'^(?:next|another|what|why|how|which|calculate|prove)\b',
        caseSensitive: false);
    if (!newQuestion.hasMatch(tail)) return false;
    return tail != text.trim() ||
        (_completedUtteranceText.isNotEmpty &&
            !AlertEventMerger.similarText(_completedUtteranceText, text));
  }

  String _afterCompletedQuestion(String text) {
    final ignored = RegExp(r'[\s。！？?!，,；;：:]');
    final canonical = text.replaceAll(ignored, '').toLowerCase();
    for (final completed in _completedAlertPrefixes) {
      final prefix = completed.replaceAll(ignored, '').toLowerCase();
      if (prefix.length < 6) continue;
      if (prefix.startsWith(canonical)) return '';
      if (!canonical.startsWith(prefix)) continue;
      var matched = 0, offset = 0;
      while (offset < text.length && matched < prefix.length) {
        if (!ignored.hasMatch(text[offset])) matched++;
        offset++;
      }
      return text
          .substring(offset)
          .replaceFirst(RegExp(r'^[\s。！？?!，,；;：:]+'), '')
          .trim();
    }
    return text;
  }

  void _rememberAlertFragment(String text,
      {required bool isFinal, required DateTime timestamp}) {
    final normalized = _afterCompletedQuestion(text.trim());
    if (normalized.isEmpty) return;
    final cutoff = now().subtract(const Duration(seconds: 15));
    _alertFragments.removeWhere(
        (fragment) => fragment.timestamp.isBefore(cutoff) || !fragment.isFinal);
    _alertFragments.add(
      _AlertFragment(text: normalized, timestamp: timestamp, isFinal: isFinal),
    );
  }

  String _refineTranscriptSegment(String text) {
    if (!(shouldRefineTranscript?.call() ?? false)) return text;
    return LocalTranscriptRefiner.refine(text);
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startedAt == null) return;
      _current = _current.copyWith(
        duration: now().difference(_startedAt!),
      );
      _emit();
    });
  }

  void _startSegmentCommitTimer() {
    _segmentCommitTimer?.cancel();
    _segmentCommitTimer = Timer.periodic(segmentCommitInterval, (_) {
      if (!_running) return;
      _flushPendingPartial();
      _commitCurrentPartial();
      _checkpointActiveSession();
    });
  }

  void _commitCurrentPartial() {
    final partial = _hypothesis.latestHypothesis.trim();
    if (partial.isEmpty) return;
    _hypothesis.commit();
    _provisionalSegmentIndex = _acceptAsrResult(
        AsrResult(
          text: partial,
          isFinal: true,
          timestamp: now(),
          language: _sessionLanguage,
        ),
        replaceSegmentIndex: _provisionalSegmentIndex,
        isProvisional: true);
  }

  void _checkpointActiveSession() {
    final session = _activeSession;
    if (session == null ||
        (!_recordingOnly &&
            session.transcript.trim().isEmpty &&
            session.events.isEmpty)) {
      return;
    }
    onSessionCheckpoint?.call(_snapshotOf(session));
  }

  static ClassSession _snapshotOf(ClassSession session) => ClassSession(
        id: session.id,
        title: session.title,
        courseName: session.courseName,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        transcript: session.transcript,
        events: session.events
            .map((event) => AlertEvent.fromJson(event.toJson()))
            .toList(),
        summary: session.summary,
        language: session.language,
      );

  void _emit() {
    if (_state.isClosed) return;
    // 每次广播都带上最新 running 状态。
    final snapshot = _current.copyWith(isRunning: _running);
    _current = snapshot;
    _state.add(snapshot);
  }

  Future<void> dispose() async {
    _disposed = true;
    _segmentCommitTimer?.cancel();
    _partialUpdateTimer?.cancel();
    await stop();
    await _state.close();
  }
}

/// 简易 StringBuilder（避免每次拼接新建字符串，高频场景更稳）。
class StringBuilder {
  final List<String> _parts = [];
  String _last = '';

  void write(String s) {
    if (s.isEmpty) return;
    _parts.add(s);
    _last = '$_last$s';
  }

  void clear() {
    _parts.clear();
    _last = '';
  }

  @override
  String toString() => _last;
}

class SegmentedTranscriptBuffer {
  final List<String> _segments = [];
  String _cached = '';
  bool _dirty = false;

  int append(String text, {bool deduplicate = true}) {
    final normalized = text.trim();
    if (normalized.isEmpty) return -1;
    if (deduplicate && _segments.isNotEmpty && _segments.last == normalized) {
      return _segments.length - 1;
    }
    _segments.add(normalized);
    if (_dirty) return _segments.length - 1;
    if (_cached.isNotEmpty &&
        _needsSpace(_lastCharacter(_cached), normalized)) {
      _cached = '$_cached $normalized';
    } else {
      _cached = '$_cached$normalized';
    }
    return _segments.length - 1;
  }

  bool replace(int index, String text) {
    if (index < 0 || index >= _segments.length) return false;
    final normalized = text.trim();
    if (normalized.isEmpty || _segments[index] == normalized) return false;
    _segments[index] = normalized;
    _dirty = true;
    return true;
  }

  void clear() {
    _segments.clear();
    _cached = '';
    _dirty = false;
  }

  @override
  String toString() {
    if (!_dirty) return _cached;
    final out = StringBuffer();
    String? previousLast;
    for (final segment in _segments) {
      if (previousLast != null && _needsSpace(previousLast, segment)) {
        out.write(' ');
      }
      out.write(segment);
      previousLast = _lastCharacter(segment);
    }
    _cached = out.toString();
    _dirty = false;
    return _cached;
  }

  static String _lastCharacter(String value) {
    return value.isEmpty ? '' : value[value.length - 1];
  }

  static bool _needsSpace(String previous, String next) {
    if (previous.isEmpty || next.isEmpty) return false;
    final left = RegExp(r'[A-Za-z0-9]').hasMatch(previous);
    final right = RegExp(r'^[A-Za-z0-9]').hasMatch(next);
    return left && right;
  }
}

class _AlertFragment {
  const _AlertFragment({
    required this.text,
    required this.timestamp,
    required this.isFinal,
  });

  final String text;
  final DateTime timestamp;
  final bool isFinal;
}

class _EnhancementRequest {
  const _EnhancementRequest({
    required this.generation,
    required this.segmentIndex,
    required this.originalText,
    required this.enhancer,
  });

  final int generation;
  final int segmentIndex;
  final String originalText;
  final Future<String> Function(String text) enhancer;
}

class _TranslationRequest {
  const _TranslationRequest({
    required this.generation,
    required this.text,
    required this.translator,
  });

  final int generation;
  final String text;
  final Future<String> Function(String text) translator;
}
