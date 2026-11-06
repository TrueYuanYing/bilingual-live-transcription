import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

final doubaoWebSessionProvider =
    ChangeNotifierProvider<DoubaoWebSession>((ref) => DoubaoWebSession());

/// A single official-page session. The WebView owns login state, not IKO settings.
class DoubaoWebSession extends ChangeNotifier {
  DoubaoWebSession({WebViewController? controller}) : _controller = controller;
  WebViewController? _controller;
  WebViewController get controller => _controller!;
  bool get initialized => _initialized;
  bool _initialized = false;
  Future<void>? _initialization;
  bool _active = false;
  bool _disposed = false;
  bool _submitting = false;
  bool _manualRequired = false;
  bool _notifyScheduled = false;
  Timer? _poll;
  String _composer = '';
  String? _pendingId;
  String? get pendingQuestionId => _pendingId;
  String pendingPrompt = '';
  String message = '下方为豆包官方页面；未登录时请登录，已有登录状态会保留在本机。';
  int progress = 0;
  final Set<String> _submitted = {};
  bool routeOpen = false;

  bool offerQuestion(String id, String text) {
    if (_submitted.contains(id) || text.trim().isEmpty) return false;
    if (_pendingId == id && pendingPrompt == text.trim()) return true;
    _pendingId = id;
    pendingPrompt = text.trim();
    _manualRequired = false;
    message = '最新问题待发送；登录完成后会尝试自动填入并发送。';
    _notify();
    return true;
  }

  Future<void> activate() async {
    if (_disposed) return;
    _active = true;
    if (!_initialized) {
      try {
        await (_initialization ??= _initialize())
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        _initialization = null;
        _initialized = false;
        rethrow;
      }
    }
    await _enablePage();
    _poll?.cancel();
    if (_active && !_disposed) {
      _poll = Timer.periodic(
          const Duration(seconds: 1), (_) => unawaited(submitPending()));
    }
    _notify();
  }

  Future<void> _initialize() async {
    _composer = await rootBundle.loadString('assets/ai/doubao-compose.js');
    if (_disposed) return;
    _controller ??= WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (request) =>
          Uri.tryParse(request.url)?.scheme == 'https'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
      onProgress: (value) {
        progress = value;
        _notify();
      },
      onPageFinished: (_) {
        unawaited(_enablePage());
      },
      onWebResourceError: (error) {
        if (error.isForMainFrame == true) {
          message = '豆包页面加载失败，可重试或使用外部浏览器。';
          _notify();
        }
      },
    ));
    await controller.loadRequest(Uri.parse('https://www.doubao.com/chat/'));
    _initialized = true;
  }

  Future<void> _enablePage() async {
    if (!_active || !_initialized || _disposed) return;
    try {
      await controller
          .runJavaScript('window.__ikoQuestionEnabled = true;')
          .timeout(const Duration(seconds: 4));
    } catch (_) {/* navigation may still be in progress */}
  }

  Future<void> submitPending() async {
    if (!_active ||
        _disposed ||
        !_initialized ||
        _submitting ||
        _manualRequired ||
        _pendingId == null) {
      return;
    }
    final id = _pendingId!;
    final text = pendingPrompt;
    _submitting = true;
    try {
      final url = Uri.tryParse(
          await controller.currentUrl().timeout(const Duration(seconds: 4)) ??
              '');
      if (!_active || _disposed || _pendingId != id || pendingPrompt != text) {
        return;
      }
      if (url?.scheme != 'https' ||
          !{'www.doubao.com', 'doubao.com'}.contains(url?.host)) {
        message = '请完成官方网页登录后返回豆包对话页，问题暂不发送。';
        return;
      }
      final result = (await controller
              .runJavaScriptReturningResult(
                  '$_composer(${jsonEncode({'id': id, 'text': text})})')
              .timeout(const Duration(seconds: 4)))
          .toString()
          .replaceAll('"', '');
      if (_disposed) return;
      if (result == 'submitted' || result == 'already_submitted') {
        _submitted.add(id);
        if (_submitted.length > 64) _submitted.remove(_submitted.first);
        if (_pendingId == id) {
          _pendingId = null;
          pendingPrompt = '';
          message = '已点击网页发送，请在下方查看回答；网页结果以豆包为准。';
        }
      } else if (_active && _pendingId == id) {
        message = switch (result) {
          'login_required' => '请先在下方登录豆包，最新问题已保留，登录后自动尝试发送。',
          'draft_conflict' => '网页中已有草稿，未覆盖。请先发送或清空草稿，再点“重试发送”。',
          'filled' => '问题已填入网页，正在等待发送按钮。',
          'generating' => '豆包正在回答上一题，最新问题等待发送。',
          'manual_send' => '问题已填入；未识别到可用的发送按钮，请在网页中手动发送。',
          _ => '等待豆包对话输入框；如网页不支持自动填写，可复制问题后手动发送。',
        };
        _manualRequired = result == 'draft_conflict' || result == 'manual_send';
      }
    } catch (_) {
      if (_active && _pendingId == id) {
        _manualRequired = true;
        message = '发送状态未确认，不会自动重复提交。请检查网页；也可复制后手动发送。';
      }
    } finally {
      _submitting = false;
      _notify();
    }
  }

  /// Discard one question while preserving login and future question polling.
  void completeQuestion(String id) {
    _submitted.add(id);
    if (_submitted.length > 64) _submitted.remove(_submitted.first);
    if (_pendingId == id) {
      _pendingId = null;
      pendingPrompt = '';
      _manualRequired = false;
      message = '此问题已完成；新问题仍会正常发送。';
      _notify();
    }
  }

  void retry() {
    _manualRequired = false;
    unawaited(submitPending());
  }

  Future<void> suspend({bool discard = false}) async {
    _active = false;
    _poll?.cancel();
    if (discard) {
      _pendingId = null;
      pendingPrompt = '';
    }
    if (_initialized) {
      try {
        await controller
            .runJavaScript('window.__ikoQuestionEnabled = false;')
            .timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    _notify();
  }

  void _notify() {
    if (_disposed || _notifyScheduled) return;
    _notifyScheduled = true;
    // Route removal may suspend the page while widgets are being disposed.
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(suspend(discard: true));
    super.dispose();
  }
}
