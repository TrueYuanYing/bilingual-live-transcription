import 'package:flutter/services.dart';

import '../../data/models/class_session.dart';
import 'alert_engine.dart';

/// Android 系统级课堂预警桥接。
///
/// Flutter UI 内的横条负责展示上下文；这里负责高优先级通知和听写前台服务，
/// 即使用户切到后台，也能把关键预警交给系统通知栏/heads-up 展示。
class SystemAlertService {
  SystemAlertService._();

  static const _channel = MethodChannel('com.classmate.classmate/system_alert');

  static Future<Map<String, dynamic>> status() async {
    try {
      return Map<String, dynamic>.from(
          await _channel.invokeMethod('getAlertStatus') as Map);
    } on MissingPluginException {
      return {'supported': false};
    } on PlatformException {
      return {'supported': false};
    }
  }

  static Future<void> openSettings() =>
      _channel.invokeMethod('openAlertSettings');
  static Future<void> testNotification() => _channel.invokeMethod('testAlert');

  static Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on MissingPluginException {
      // 非 Android 平台无原生通道，桌面端保持静默。
    } on PlatformException {
      // 权限被系统拒绝不应阻断听写。
    }
  }

  static Future<void> startForegroundCapture() async {
    try {
      await _channel.invokeMethod<void>('startForegroundCapture');
    } on MissingPluginException {
      // Flutter test / Windows 无需前台服务。
    }
  }

  static Future<void> stopForegroundCapture() async {
    try {
      await _channel.invokeMethod<void>('stopForegroundCapture');
    } on MissingPluginException {
      // 非 Android 平台忽略。
    } on PlatformException {
      // 停止服务失败不影响会话收尾。
    }
  }

  static Future<void> show(AlertEvent event) async {
    final confirmedPersonal = event.confidence >= 0.99;
    final title = confirmedPersonal ? 'IKO · 命中本人' : 'IKO · 课堂预警';
    final shortTrigger = AlertTextCompactor.compact(event.triggerText);
    final shortQuestion = AlertTextCompactor.compactNullable(event.question);
    final body = confirmedPersonal
        ? '已识别到你的点名或学号：$shortTrigger'
        : event.type == AlertType.question
            ? '可能正在提问：${shortQuestion ?? shortTrigger}'
            : '可能正在点名：$shortTrigger';
    try {
      await _channel.invokeMethod<void>('showAlert', {
        'title': title,
        'body': body,
        'confirmed': confirmedPersonal,
        'severity': confirmedPersonal ? 'red' : 'yellow',
      });
    } on MissingPluginException {
      // 非 Android 平台由页面内预警承担展示。
    } on PlatformException {
      // 系统通知失败不影响本地字幕和 AI 回答。
    }
  }
}
