import 'package:test/test.dart';
import 'package:iko_classroom/services/asr/start_capture.dart';

void main() {
  test('permission denial never starts Android microphone service', () async {
    final calls = <String>[];
    await expectLater(
        startCapture(
          requestPermission: () async => false,
          startForeground: () async => calls.add('foreground'),
          startSession: () async => calls.add('session'),
          stopForeground: () async => calls.add('stop foreground'),
          stopSession: () async => calls.add('stop session'),
        ),
        throwsStateError);
    expect(calls, isEmpty);
  });
  test('permission then foreground acknowledgment then model and audio',
      () async {
    final calls = <String>[];
    await startCapture(
      requestPermission: () async {
        calls.add('permission');
        return true;
      },
      startForeground: () async => calls.add('foreground'),
      startSession: () async => calls.add('session'),
      stopForeground: () async => calls.add('stop foreground'),
      stopSession: () async => calls.add('stop session'),
    );
    expect(calls, ['permission', 'foreground', 'session']);
  });
  test('failed model or audio initialization releases session and service',
      () async {
    final calls = <String>[];
    await expectLater(
        startCapture(
          requestPermission: () async => true,
          startForeground: () async => calls.add('foreground'),
          startSession: () async => throw StateError('model unavailable'),
          stopForeground: () async => calls.add('stop foreground'),
          stopSession: () async => calls.add('stop session'),
        ),
        throwsStateError);
    expect(calls, ['foreground', 'stop session', 'stop foreground']);
  });
}
