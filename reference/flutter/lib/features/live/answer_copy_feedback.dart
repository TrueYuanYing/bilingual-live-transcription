import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final _notices = Expando<OverlayEntry>();

/// No route/focus change: the native notes pane stays mounted while copying.
Future<void> copyAnswerWithFeedback(BuildContext context, String text) async {
  var success = true;
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } on PlatformException {
    success = false;
  }
  if (!context.mounted) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  if (!overlay.mounted) return;
  final box = context.findRenderObject() as RenderBox?;
  final host = overlay.context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize || host == null) return;
  final center =
      host.globalToLocal(box.localToGlobal(box.size.center(Offset.zero)));
  final theme = Theme.of(context);
  final hostSize = host.size;
  _notices[overlay]?.remove();
  late final OverlayEntry entry;
  void dismiss() {
    if (_notices[overlay] != entry) return;
    _notices[overlay] = null;
    entry.remove();
  }

  entry = OverlayEntry(
      builder: (_) => Positioned(
          left: (center.dx - 100)
              .clamp(8, (hostSize.width - 208).clamp(8, double.infinity)),
          top: (center.dy - 26)
              .clamp(8, (hostSize.height - 60).clamp(8, double.infinity)),
          width: 200,
          child: IgnorePointer(
              child: _CopyNotice(
                  theme: theme, success: success, onDismiss: dismiss))));
  _notices[overlay] = entry;
  overlay.insert(entry);
}

class _CopyNotice extends StatefulWidget {
  const _CopyNotice(
      {required this.theme, required this.success, required this.onDismiss});
  final ThemeData theme;
  final bool success;
  final VoidCallback onDismiss;
  @override
  State<_CopyNotice> createState() => _CopyNoticeState();
}

class _CopyNoticeState extends State<_CopyNotice> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1400), widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
      elevation: 6,
      color: widget.theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Semantics(
              liveRegion: true,
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(
                    widget.success
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 20,
                    color: widget.theme.colorScheme.onSurface),
                const SizedBox(width: 8),
                Flexible(
                    child: Text(widget.success ? '复制成功' : '复制失败，请重试',
                        style: widget.theme.textTheme.bodyMedium?.copyWith(
                            color: widget.theme.colorScheme.onSurface))),
              ]))));
}
