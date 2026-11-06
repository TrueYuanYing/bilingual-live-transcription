import 'package:flutter/material.dart';
import '../../data/models/class_session.dart';

/// Transfers only the existing answer UI while its listening page stays mounted.
/// The original page continues to own the one in-flight request and its actions.
final liveAnswerPresentation = LiveAnswerPresentation();

class LiveAnswerPresentation extends ChangeNotifier {
  Object? _owner;
  String? _event;
  AlertEvent? currentEvent;
  Widget? view;
  bool _scheduled = false;
  bool get hasView => _owner != null && view != null;
  String _identity(AlertEvent event) =>
      '${event.timestamp.microsecondsSinceEpoch}:${event.type.name}';
  bool matches(AlertEvent? event) =>
      event != null && _owner != null && _event == _identity(event);

  void publish(Object owner, AlertEvent event, Widget widget) {
    _owner = owner;
    currentEvent = event;
    _event = _identity(event);
    view = widget;
    _scheduleNotification();
  }

  void _scheduleNotification() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void clear(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    currentEvent = null;
    _event = null;
    view = null;
    _scheduleNotification();
  }
}
