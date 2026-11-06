import '../notes/notes_pane.dart';
import '../notes/notes_live_text.dart';
import 'answer_card_layout.dart';
import 'answer_copy_feedback.dart';
import 'live_answer_presentation.dart';
import 'classroom_notes_split.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/navigation.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/widgets/app_widgets.dart';
import '../../data/models/app_settings.dart';
import '../ai/doubao_web_screen.dart';
import '../../data/models/class_session.dart';
import '../../services/asr/live_session_controller.dart';
import '../../services/asr/start_capture.dart';
import '../../services/asr/live_transcript_window.dart';
import '../../services/asr/mixed_language_text.dart';
import '../../services/ai/ai_answer_service.dart';
import '../../services/ai/doubao_web_session.dart';
import '../../services/alert/question_context.dart';
import '../../services/alert/system_alert_service.dart';
import '../../core/inline_translation_provider.dart';
import 'translated_transcript_text.dart';
import 'classroom_recording_widgets.dart';

/// 实时听写页：滚动字幕（partial 灰 / final 黑）+ 时长 + 预警卡片 + 悬浮窗开关。
class LiveCaptureScreen extends ConsumerStatefulWidget {
  const LiveCaptureScreen({super.key});

  @override
  ConsumerState<LiveCaptureScreen> createState() => _LiveCaptureScreenState();
}

class _LiveCaptureScreenState extends ConsumerState<LiveCaptureScreen>
    with RouteAware {
  final ScrollController _scroll = ScrollController();
  StreamSubscription<LiveSessionState>? _sub;
  int _lastTranscriptLength = 0;
  int _lastTranslationLength = 0;
  String _lastPartial = '';
  bool _scrollScheduled = false;
  bool _toggling = false;
  bool _notesOpen = false;
  Widget? _notesPane;
  final _alertKey = GlobalKey();
  bool _showReturnToLatest = false;
  final LiveTranscriptFollowPolicy _followPolicy = LiveTranscriptFollowPolicy();
  late final StateController<bool> _captureVisibility;
  ModalRoute<dynamic>? _route;

  void _setVisible(bool visible) {
    Future.microtask(() {
      if (_captureVisibility.mounted) _captureVisibility.state = visible;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route && route != null) {
      appRouteObserver.unsubscribe(this);
      _route = route;
      appRouteObserver.subscribe(this, route);
      registerDoubaoCaptureRoute(route);
    }
  }

  @override
  void didPushNext() => _setVisible(false);

  @override
  void didPopNext() => _setVisible(true);

  @override
  void didPop() => _setVisible(false);

  @override
  void initState() {
    super.initState();
    _captureVisibility = ref.read(liveCaptureVisibleProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _captureVisibility.mounted) {
        _captureVisibility.state = true;
      }
    });
    // 订阅会话状态流，让 UI 跟随 开始/停止/计时/转写 实时刷新。
    _scroll.addListener(_onScrollChanged);
    ref.listenManual<LiveSessionController>(
        liveSessionProvider, (_, live) => _bindLive(live),
        fireImmediately: true);
    ref.listenManual(inlineTranslationsProvider, (previous, next) {
      _scheduleScrollToLatest();
    });
  }

  void _bindLive(LiveSessionController live) {
    _sub?.cancel();
    final initial = live.current;
    _lastTranscriptLength = initial.transcript.length;
    _lastTranslationLength = initial.translation.length;
    _lastPartial = initial.livePartial;
    _sub = live.state.listen((state) {
      if (!mounted) return;
      final transcriptChanged =
          state.transcript.length != _lastTranscriptLength ||
              state.translation.length != _lastTranslationLength ||
              state.livePartial != _lastPartial;
      _lastTranscriptLength = state.transcript.length;
      _lastTranslationLength = state.translation.length;
      _lastPartial = state.livePartial;
      setState(() {});
      if (transcriptChanged) _scheduleScrollToLatest();
    });
  }

  void _scheduleScrollToLatest() {
    if (!_followPolicy.followLatest) return;
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _onScrollChanged() {
    if (!_scroll.hasClients) return;
    final before = _showReturnToLatest;
    final nearLatest = _followPolicy.update(
      offset: _scroll.offset,
      maxExtent: _scroll.position.maxScrollExtent,
    );
    if (!mounted) return;
    _showReturnToLatest = _followPolicy.showReturnToLatest;
    if (before != _showReturnToLatest || nearLatest && before) {
      setState(() {});
    }
  }

  void _returnToLatest() {
    if (!_scroll.hasClients) return;
    _followPolicy.followLatest = true;
    _followPolicy.showReturnToLatest = false;
    _showReturnToLatest = false;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    unregisterDoubaoCaptureRoute(_route);
    _sub?.cancel();
    _scroll.removeListener(_onScrollChanged);
    _scroll.dispose();
    // Provider notifications must run outside the widget build/dispose phase.
    final visibility = _captureVisibility;
    Future.microtask(() {
      if (visibility.mounted) visibility.state = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveSessionProvider);
    final state = live.current;
    final theme = Theme.of(context);

    final settings = ref.watch(settingsProvider).valueOrNull;
    final translations = ref.watch(inlineTranslationsProvider);
    final showTranslations =
        settings?.translationEnabled == true && settings?.activated == true;
    final webMode = settings?.answerMode == QuestionAnswerMode.web;
    final language = state.isRunning
        ? state.language
        : settings?.engine == 'cloud'
            ? 'auto'
            : settings?.recognitionLanguage ?? 'auto';
    final transcript = Column(children: [
      Expanded(
          child: CaptureTranscriptViewport(
        before: [
          _StatusBar(
              state: state,
              language: language,
              engine: settings?.engine ?? 'local'),
          const ClassroomRecordingControl(),
          if (state.error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(state.error!,
                    style: TextStyle(color: theme.colorScheme.error))),
        ],
        after: [
          if (state.alerts.isNotEmpty)
            _AlertBanner(
                key: _alertKey,
                alerts: state.alerts,
                theme: theme,
                sourceText: QuestionContext.sourceText(
                    state.transcript, state.livePartial)),
          if (_toggling)
            const Padding(
                padding: EdgeInsets.all(12),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('正在准备听写…'),
                ])),
        ],
        builder: (before, after) {
          return Stack(
            children: [
              GestureDetector(
                onTap: () => FocusScope.of(context).unfocus(),
                child: _TranscriptView(
                    before: before,
                    after: after,
                    scroll: _scroll,
                    state: state,
                    translations:
                        showTranslations ? translations.translations : const {},
                    translationError:
                        showTranslations ? translations.error : null,
                    onRetryTranslations:
                        showTranslations && translations.hasFailures
                            ? translations.retryFailed
                            : null),
              ),
              if (_followPolicy.showReturnToLatest)
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: Material(
                    color: theme.colorScheme.surface,
                    elevation: 5,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: _returnToLatest,
                      borderRadius: BorderRadius.circular(20),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.arrow_downward_rounded, size: 16),
                          SizedBox(width: 5),
                          Text('回到最新'),
                        ]),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      )),
      if (!_notesOpen)
        _BottomControls(
            running: state.isRunning,
            onToggle: () => _toggle(live),
            theme: theme),
    ]);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.isRunning)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.fiber_manual_record,
                    color: AppColors.pink, size: 12),
              ),
            Flexible(
                child: Text(state.isRunning ? '听写中' : '听写',
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
              tooltip: _notesOpen ? '收起笔记' : '分屏笔记',
              icon: const Icon(Icons.edit_note_rounded),
              onPressed: () {
                if (_notesOpen) {
                  _closeNotes();
                } else {
                  setState(() => _notesOpen = true);
                }
              }),
          if (webMode)
            TextButton.icon(
              onPressed: () => openLatestDoubaoQuestion(context, ref,
                  question: AlertEventMerger.latestForDisplay(state.alerts)
                          ?.question ??
                      ''),
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              label: const Text('发送问题'),
            ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            onPressed: _toggling ? null : () => _showSettings(context),
          ),
        ],
      ),
      body: SafeArea(
        child: _notesOpen
            ? ClassroomNotesSplit(
                transcript: Column(children: [
                  Expanded(child: transcript),
                  _BottomControls(
                      running: state.isRunning,
                      onToggle: () => _toggle(live),
                      theme: theme)
                ]),
                notes: _notesPane ??= RepaintBoundary(
                    child: NotesPane(compact: true, onClose: _closeNotes)),
                onClose: _closeNotes,
                onExpand: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const NotesPage())),
              )
            : webMode
                ? DoubaoCaptureSplit(
                    transcript: transcript,
                    keyboardControls: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(children: [
                          Expanded(
                              child: Text(
                                  state.livePartial.isNotEmpty
                                      ? state.livePartial
                                      : state.isRunning
                                          ? '正在听写'
                                          : '听写未开始',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                          TextButton.icon(
                              onPressed: _toggling ? null : () => _toggle(live),
                              icon: Icon(state.isRunning
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded),
                              label: Text(state.isRunning ? '停止听写' : '开始听写')),
                        ])),
                    keyboardVisible:
                        MediaQuery.viewInsetsOf(context).bottom > 0)
                : transcript,
      ),
    );
  }

  Future<void> _closeNotes() async {
    await ref
        .read(notesCoordinatorProvider)
        .channel
        .invokeMethod<void>('hideWorkspace')
        .catchError((_) {});
    if (mounted) setState(() => _notesOpen = false);
  }

  Future<void> _toggle(LiveSessionController controller) async {
    if (_toggling) return;
    setState(() => _toggling = true);
    try {
      if (controller.current.isRunning) {
        await controller.stop();
        await SystemAlertService.stopForegroundCapture();
      } else {
        try {
          await startCapture(
            requestPermission: () async {
              if (!await controller.audio.requestPermission()) return false;
              final settings = ref.read(settingsProvider).valueOrNull;
              if (settings?.engine != 'system') {
                final language = settings?.engine == 'cloud'
                    ? 'auto'
                    : settings?.recognitionLanguage ?? 'zh';
                final models = await ref.read(modelManagerProvider.future);
                await models.prepare(
                    language: language, onProgress: (_, __) {});
              }
              return true;
            },
            startForeground: SystemAlertService.startForegroundCapture,
            startSession: controller.start,
            stopForeground: SystemAlertService.stopForegroundCapture,
            stopSession: controller.stop,
          );
          await SystemAlertService.requestNotificationPermission();
        } catch (e) {
          await SystemAlertService.stopForegroundCapture();
          if (!mounted) return;
          final msg = e.toString().contains('权限')
              ? '需要麦克风权限才能听写，请在系统设置里为 IKO 开启麦克风权限'
              : '启动失败：$e';
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) => ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .88),
          child: const SingleChildScrollView(child: _QuickSettingsSheet())),
    );
  }
}

/// 顶部状态条。
class _StatusBar extends StatelessWidget {
  const _StatusBar(
      {required this.state, required this.language, required this.engine});
  final LiveSessionState state;
  final String language;
  final String engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        children: [
          Tooltip(
            message: switch (engine) {
              'cloud' => '云端增强识别',
              'system' => '系统增强识别',
              _ => '本地离线识别',
            },
            child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                    switch (engine) {
                      'cloud' => Icons.cloud_outlined,
                      'system' => Icons.record_voice_over_outlined,
                      _ => Icons.graphic_eq_rounded,
                    },
                    size: 20,
                    color: AppColors.secondaryLabel)),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 时长
          Text(
            _fmt(state.duration),
            style: tabularFigures(theme.textTheme.titleMedium!),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.fill(theme.brightness),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Text(
              switch (language) {
                'en' => 'EN → 译',
                'auto' => '中英',
                _ => '中文',
              },
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 字幕视图：final 正文 + partial 实时行。
class _TranscriptView extends StatelessWidget {
  const _TranscriptView(
      {required this.scroll,
      required this.state,
      required this.translations,
      this.translationError,
      this.before = const [],
      this.after = const [],
      this.onRetryTranslations});
  final List<Widget> before, after;
  final ScrollController scroll;
  final LiveSessionState state;
  final Map<String, String> translations;
  final String? translationError;
  final VoidCallback? onRetryTranslations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 这里展示完整正文，用户可以回看整节课；只在接近底部时自动跟随。
    final finalText = state.transcript;
    final partial = state.livePartial;

    return CustomScrollView(
      controller: scroll,
      slivers: [
        SliverPadding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            sliver: SliverMainAxisGroup(slivers: [
              SliverList.list(children: before),
              if (finalText.isNotEmpty)
                TranslatedTranscriptSliver(
                  text: finalText,
                  style: theme.textTheme.bodyLarge!,
                  translations: translations,
                ),
              SliverList.list(children: [
                if (translationError != null)
                  Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(translationError!,
                          style: theme.textTheme.bodySmall)),
                if (onRetryTranslations != null)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                          onPressed: onRetryTranslations,
                          icon: const Icon(Icons.translate_rounded, size: 18),
                          label: const Text('补译未完成英文（使用 API）'))),
                if (partial.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _MixedTranscriptText(
                    text: partial,
                    style: theme.textTheme.bodyLarge!.copyWith(
                      color: AppColors.secondaryLabel,
                    ),
                  ),
                ],
                if (finalText.isEmpty && partial.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: Column(
                        children: [
                          Icon(Icons.graphic_eq_rounded,
                              size: 48,
                              color: AppColors.secondaryLabel
                                  .withValues(alpha: 0.4)),
                          const SizedBox(height: AppSpacing.md),
                          Text(state.isRunning ? '正在聆听，请开始说话' : '点击下方开始听写',
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ...after,
              ]),
            ]))
      ],
    );
  }
}

/// 混合句只强调英文片段，避免整句在中英文模型之间来回染色。
class _MixedTranscriptText extends StatelessWidget {
  const _MixedTranscriptText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final spans = MixedLanguageText.spans(text);
    if (spans.length <= 1) return Text(text, style: style);
    return RichText(
      text: TextSpan(
        children: [
          for (final span in spans)
            TextSpan(
              text: span.text,
              style: span.language == TranscriptSpanLanguage.english
                  ? style.copyWith(
                      color: AppColors.tint,
                      fontWeight: FontWeight.w600,
                    )
                  : style,
            ),
        ],
      ),
    );
  }
}

/// 预警提示横条 + AI 自动回答。
class _AlertBanner extends ConsumerStatefulWidget {
  const _AlertBanner(
      {super.key,
      required this.alerts,
      required this.theme,
      required this.sourceText});
  final List<AlertEvent> alerts;
  final ThemeData theme;
  final String sourceText;

  @override
  ConsumerState<_AlertBanner> createState() => _AlertBannerState();
}

class _AlertBannerState extends ConsumerState<_AlertBanner> {
  String? _answer; // AI 回答
  bool _loading = false; // 正在生成
  bool _answered = false; // 当前条是否已生成过（避免重复请求）
  String? _lastNotifiedKey;
  Timer? _answerTimer;
  int _answerRevision = 0;
  CancelToken? _answerToken;
  late AlertEvent _displayEvent;
  late String _displaySource;
  AlertEvent? _candidate;
  String _candidateSource = '';
  Timer? _advanceTimer;
  bool _protectionExpired = false;

  bool _sameQuestion(AlertEvent a, AlertEvent b) => a.timestamp == b.timestamp;

  void _startReadWindow() {
    _protectionExpired = false;
    _advanceTimer?.cancel();
    _advanceTimer = Timer(const Duration(seconds: 25), () {
      _protectionExpired = true;
      if (mounted) _queueAdvance();
    });
  }

  void _queueAdvance() {
    if (_candidate == null ||
        _loading ||
        !_protectionExpired ||
        ref.read(settingsProvider).valueOrNull?.answerMode !=
            QuestionAnswerMode.api) {
      return;
    }
    _advanceTimer?.cancel();
    _advanceTimer = Timer(Duration.zero, () {
      if (mounted) _updateQuestion();
    });
  }

  void _updateQuestion() {
    final next = _candidate;
    if (next == null || next.isCompleted) return;
    _advanceTimer?.cancel();
    _answerTimer?.cancel();
    _answerToken?.cancel('manual or protected question update');
    _answerRevision++;
    setState(() {
      _displayEvent = next;
      _displaySource = _candidateSource;
      _candidate = null;
      _protectionExpired = false;
      _answer = null;
      _loading = false;
      _answered = false;
    });
    _maybeAutoAnswer();
  }

  @override
  void initState() {
    super.initState();
    _displayEvent = AlertEventMerger.latestForDisplay(widget.alerts)!;
    _displaySource = widget.sourceText;
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLatest());
    ref.listenManual(settingsProvider, (previous, next) {
      if (next.valueOrNull?.answerMode != QuestionAnswerMode.api) {
        _answerTimer?.cancel();
        _advanceTimer?.cancel();
        _protectionExpired = false;
        _candidate = null;
        _candidateSource = '';
        _answerToken?.cancel('web question mode');
        _answerRevision++;
        if (mounted) {
          setState(() {
            _loading = false;
            _answered = false;
            _answer = null;
          });
        }
      } else if (next.valueOrNull?.answerMode == QuestionAnswerMode.api &&
          (previous?.valueOrNull == null ||
              previous?.valueOrNull?.answerMode != QuestionAnswerMode.api)) {
        _scheduleAnswer();
      }
    });
    _scheduleAnswer();
  }

  @override
  void didUpdateWidget(covariant _AlertBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final latest = AlertEventMerger.latestForDisplay(widget.alerts)!;
    // Initial debounce may gather a fuller question. Once generation begins,
    // the request and visible question share the same immutable source snapshot.
    if (!_answered && !_loading && !_displayEvent.isCompleted) {
      _displayEvent = latest;
      _displaySource = widget.sourceText;
      if (QuestionContext.shouldRefreshAnswer(
          oldWidget.sourceText, widget.sourceText)) {
        _scheduleAnswer();
      }
      return;
    }
    if (_displayEvent.isCompleted &&
        !_sameQuestion(_displayEvent, latest) &&
        !latest.isCompleted) {
      _candidate = latest;
      _candidateSource = widget.sourceText;
      _updateQuestion();
      return;
    }
    if (_sameQuestion(_displayEvent, latest) && latest.isCompleted) {
      _displayEvent = latest;
      if (_candidate != null && _sameQuestion(_candidate!, latest)) {
        _candidate = null;
        _advanceTimer?.cancel();
      }
      return;
    }
    final changed = !_sameQuestion(_displayEvent, latest) ||
        _displayEvent.question != latest.question ||
        _displayEvent.triggerText != latest.triggerText ||
        QuestionContext.shouldRefreshAnswer(
            oldWidget.sourceText, widget.sourceText);
    if (changed &&
        !latest.isCompleted &&
        !(_displayEvent.isCompleted && _sameQuestion(_displayEvent, latest))) {
      _candidate = latest;
      _candidateSource = widget.sourceText;
      _queueAdvance();
    } else if (_candidate != null && _sameQuestion(_candidate!, latest)) {
      // Keep ordinary follow-up context current without another API request.
      _candidateSource = widget.sourceText;
    }
  }

  void _scheduleAnswer() {
    _answerTimer?.cancel();
    if (_displayEvent.isCompleted) {
      return;
    }
    _answerTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) _maybeAutoAnswer();
    });
  }

  @override
  void dispose() {
    liveAnswerPresentation.clear(this);
    _advanceTimer?.cancel();
    _answerTimer?.cancel();
    _answerRevision++;
    _answerToken?.cancel('banner disposed');
    super.dispose();
  }

  void _notifyLatest() {
    if (!mounted || widget.alerts.isEmpty) return;
    // 主听写页已经有底部红/黄预警卡。系统通知和顶部弹窗只由全局层在
    // 离开听写页后负责，避免一次事件同时出现两套提醒。
    final event = AlertEventMerger.latestForDisplay(widget.alerts)!;
    final key = '${event.timestamp.microsecondsSinceEpoch}:${event.type.name}';
    if (_lastNotifiedKey == key) return;
    _lastNotifiedKey = key;
  }

  @override
  Widget build(BuildContext context) {
    final last = _displayEvent;
    final personal =
        last.confidence >= 0.99 ||
        (AlertEventMerger.latestForDisplay(widget.alerts)?.confidence ?? 0) >= 0.99;
    final color = personal ? AppColors.pink : AppColors.orange;
    final foreground = personal ? Colors.white : Colors.black;
    final question = last.question ?? last.triggerText;
    final mode = ref.watch(settingsProvider).valueOrNull?.answerMode ??
        QuestionAnswerMode.off;
    final answer = _answer ?? last.savedAnswer;
    final textStyle = widget.theme.textTheme.bodyMedium?.copyWith(
      color: foreground,
    );
    void complete() {
      _answerTimer?.cancel();
      _answerRevision++;
      _answerToken?.cancel('question completed');
      final web = ref.read(doubaoWebSessionProvider);
      web.completeQuestion('${last.timestamp.microsecondsSinceEpoch}');
      ref.read(liveSessionProvider).completeQuestion(last, answer: _answer);
      setState(() {
        last.isCompleted = true;
        _loading = false;
        _startReadWindow();
        if (_candidate != null && _sameQuestion(last, _candidate!)) {
          _candidate = null;
        }
      });
      _queueAdvance();
    }

    final presentation = LayoutBuilder(
      builder: (context, limits) {
        final compact =
            limits.maxWidth < 470 * MediaQuery.textScalerOf(context).scale(1);
        Widget action(String label, IconData icon, VoidCallback? onTap) =>
            compact
                ? IconButton(
                    tooltip: label,
                    onPressed: onTap,
                    color: foreground,
                    icon: Icon(icon, size: 20),
                  )
                : TextButton.icon(
                    onPressed: onTap,
                    style: TextButton.styleFrom(
                      foregroundColor: foreground,
                      minimumSize: const Size(44, 44),
                      disabledForegroundColor: foreground.withValues(alpha: .6),
                    ),
                    icon: Icon(icon, size: 18),
                    label: Text(label),
                  );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: EdgeInsets.fromLTRB(
            compact ? 8 : AppSpacing.lg,
            0,
            compact ? 8 : AppSpacing.lg,
            AppSpacing.sm,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : AppSpacing.md,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: personal ? color : const Color(0xFFFFD54A),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          child: AnswerCardLayout(
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      last.type == AlertType.rollCall
                          ? Icons.person_pin_rounded
                          : Icons.help_rounded,
                      color: foreground,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        personal
                            ? '已命中本人：$question'
                            : last.type == AlertType.rollCall
                                ? '疑似点名：$question'
                                : '疑似提问：$question',
                        style: textStyle?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (_candidate != null) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                        child: Text(
                            _loading
                                ? '可更新问题 · 当前回答继续生成'
                                : '可更新问题 · 答案生成后保留25秒再自动更新',
                            style: textStyle)),
                    TextButton(
                        onPressed: _updateQuestion,
                        style:
                            TextButton.styleFrom(foregroundColor: foreground),
                        child: const Text('更新问题')),
                  ]),
                ],
                const SizedBox(height: 6),
                if (last.isCompleted) ...[
                  Text('此问题已完成 · 记录已保留', style: textStyle),
                  if (answer != null) SelectableText(answer, style: textStyle),
                ] else if (mode == QuestionAnswerMode.off)
                  Text('仅提醒问题 · 问答已关闭', style: textStyle)
                else if (mode == QuestionAnswerMode.web)
                  Text('问题将在右侧或下方豆包中回答', style: textStyle)
                else if (_loading) ...[
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: foreground,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('AI 正在生成回答…', style: textStyle)),
                      IconButton(
                        tooltip: '取消生成',
                        color: foreground,
                        icon: const Icon(Icons.stop_circle_outlined),
                        onPressed: () {
                          _answerRevision++;
                          _answerToken?.cancel('user canceled');
                          setState(() {
                            _loading = false;
                            _answer = '已取消生成，可重新生成。';
                          });
                        },
                      ),
                    ],
                  ),
                  if (_answer != null) Text(_answer!, style: textStyle),
                ] else if (_answer != null)
                  GestureDetector(
                    onTap: () => copyAnswerWithFeedback(context, _answer!),
                    child: Text('AI 建议：$_answer', style: textStyle),
                  )
                else
                  TextButton.icon(
                    onPressed: _generate,
                    style: TextButton.styleFrom(foregroundColor: foreground),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('生成 AI 回答'),
                  ),
              ],
            ),
            actions: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (answer != null && !_loading)
                  action(
                    '复制回答',
                    Icons.copy_rounded,
                    () => copyAnswerWithFeedback(context, answer),
                  ),
                if (mode == QuestionAnswerMode.api &&
                    !last.isCompleted &&
                    !_loading)
                  if (compact)
                    action('重新生成', Icons.refresh_rounded, _generate)
                  else
                    SizedBox(
                      height: 44,
                      child: Center(child: _retryBtn(foreground)),
                    ),
                action(
                  '此问题已完成',
                  last.isCompleted
                      ? Icons.check_circle_rounded
                      : Icons.task_alt_rounded,
                  last.isCompleted ? null : complete,
                ),
              ],
            ),
          ),
        );
      },
    );
    liveAnswerPresentation.publish(this, last, presentation);
    return presentation;
  }

  /// 按设置决定是否自动生成。
  void _maybeAutoAnswer() {
    if (_answered || _loading || _displayEvent.isCompleted) {
      return;
    }
    // 读设置里的自动开关。
    final apiMode = ref.read(settingsProvider).valueOrNull?.answerMode ==
        QuestionAnswerMode.api;
    if (apiMode) {
      _generate();
    }
  }

  Widget _retryBtn(Color foreground) {
    return InkWell(
      onTap: _generate,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh_rounded, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text('重新生成',
              style: widget.theme.textTheme.bodySmall
                  ?.copyWith(color: foreground)),
        ],
      ),
    );
  }

  /// 取最近一段转写作为上下文，让 AI 从上下文里找问题并回答。
  Future<void> _generate() async {
    if (_loading ||
        _displayEvent.isCompleted ||
        ref.read(settingsProvider).valueOrNull?.answerMode !=
            QuestionAnswerMode.api) {
      return;
    }
    _answerTimer?.cancel();
    _advanceTimer?.cancel();
    _protectionExpired = false;
    final revision = ++_answerRevision;
    final token = CancelToken();
    _answerToken = token;
    setState(() {
      _answer = null;
      _loading = true;
      _answered = true;
    });
    try {
      final event = _displayEvent;
      final ctx = QuestionContext.build(
          transcript: _displaySource,
          question: event.question ?? event.triggerText);
      final ai = ref.read(aiAnswerServiceProvider);
      final keywords = await ref
          .read(keywordManagerProvider.future)
          .timeout(const Duration(seconds: 8));
      if (!mounted || revision != _answerRevision || token.isCancelled) return;
      final answerLanguage = LiveSessionController.detectTranscriptLanguage([
        _displaySource,
        event.question ?? event.triggerText,
      ].where((value) => value.trim().isNotEmpty).join('\n'));
      final ans = await ai.answer(
        context: ctx.isEmpty ? '（无转写内容）' : ctx,
        subjectContext: keywords.contextLine(),
        language: answerLanguage,
        cancelToken: token,
        onProgress: (text) {
          if (mounted && revision == _answerRevision) {
            setState(() => _answer = text);
          }
        },
      );
      if (!mounted || revision != _answerRevision) return;
      event.savedAnswer = ans;
      for (final stored in ref.read(liveSessionProvider).current.alerts) {
        if (_sameQuestion(event, stored)) stored.savedAnswer = ans;
      }
      setState(() => _answer = ans);
    } catch (e) {
      if (!mounted || revision != _answerRevision) return;
      setState(() => _answer = '（${AiAnswerService.friendlyError(e)}）');
    } finally {
      if (mounted && revision == _answerRevision) {
        setState(() {
          _loading = false;
          _startReadWindow();
        });
        _queueAdvance();
      }
    }
  }
}

/// 底部控制按钮。
class _BottomControls extends StatelessWidget {
  const _BottomControls(
      {required this.running, required this.onToggle, required this.theme});
  final bool running;
  final VoidCallback onToggle;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
      child: Row(
        children: [
          if (running) ...[
            OutlinedButton.icon(
              onPressed: onToggle,
              icon: Icon(Icons.stop_rounded, color: AppColors.pink),
              label: const Text('结束'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.pink,
                side: const BorderSide(color: AppColors.pink),
                minimumSize: const Size(0, 50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill)),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: PillButton(
              label: running ? '听写中' : '开始听写',
              color: running
                  ? AppColors.card(theme.brightness)
                  : AppColors.accent(theme.brightness),
              onPressed: running ? null : onToggle,
              expanded: true,
              height: 50,
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h == '00' ? '$m:$s' : '$h:$m:$s';
}

/// 听写页内快捷设置（预警/翻译开关，与设置页共享同一份状态）。
class _QuickSettingsSheet extends ConsumerWidget {
  const _QuickSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(settingsProvider.notifier);
    final settings = ref.watch(settingsProvider).valueOrNull;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('听写设置', style: theme.textTheme.titleLarge),
            const NotesLiveTextSetting(),
            const SizedBox(height: AppSpacing.md),
            _SettingToggleRow(
              title: '点名/提问预警',
              value: settings?.alertEnabled ?? true,
              onChanged: (v) =>
                  notifier.apply((s) => s.copyWith(alertEnabled: v)),
            ),
            _SettingToggleRow(
              title: '英文自动翻译（使用 API）',
              value: settings?.translationEnabled ?? false,
              onChanged: (v) =>
                  notifier.apply((s) => s.copyWith(translationEnabled: v)),
            ),
            _SettingToggleRow(
              title: '智能分句与本地整理',
              value: settings?.smartTranscriptEnabled ?? false,
              onChanged: (v) =>
                  notifier.apply((s) => s.copyWith(smartTranscriptEnabled: v)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '开启后只在本机整理标点和段落；云端纠错仍需单独同意。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('识别语种', style: theme.textTheme.labelLarge),
            ),
            const SizedBox(height: AppSpacing.xs),
            LanguageModeSelector(
              value: settings?.recognitionLanguage ?? 'zh',
              onChanged: notifier.setRecognitionLanguage,
            ),
            const SizedBox(height: AppSpacing.sm),
            PillButton(
                label: '完成',
                onPressed: () => Navigator.pop(context),
                expanded: true),
          ],
        ),
      ),
    );
  }
}

class _SettingToggleRow extends StatelessWidget {
  const _SettingToggleRow(
      {required this.title, required this.value, required this.onChanged});
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: theme.textTheme.bodyLarge)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
