/// Android requires microphone permission before creating a microphone service.
Future<void> startCapture({
  required Future<bool> Function() requestPermission,
  required Future<void> Function() startForeground,
  required Future<void> Function() startSession,
  required Future<void> Function() stopForeground,
  required Future<void> Function() stopSession,
}) async {
  if (!await requestPermission()) throw StateError('麦克风权限未授予');
  try {
    await startForeground();
    await startSession();
  } catch (_) {
    try {
      await stopSession();
    } finally {
      await stopForeground();
    }
    rethrow;
  }
}
