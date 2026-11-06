import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/class_session.dart';
import 'session_title_inference.dart';

/// 课堂记录存储：用 SharedPreferences 存 ClassSession 列表 JSON。
/// 简单可靠，web/移动端通用。
class SessionStore {
  SessionStore._(this._prefs, this._sessions);

  final SharedPreferences _prefs;
  final List<ClassSession> _sessions;
  Future<void> _writeTail = Future<void>.value();

  Future<void> get settled => _writeTail;

  static const _key = 'class_sessions';
  static const _checkpointKey = 'class_session_checkpoint';
  static const _compressedPrefix = 'gz1:';

  static Future<SessionStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final sessions = _decode(prefs.getString(_key));
    final checkpoint = _decodeOne(prefs.getString(_checkpointKey));
    if (checkpoint != null) {
      final index = sessions.indexWhere((s) => s.id == checkpoint.id);
      if (index >= 0) {
        sessions[index] = checkpoint;
      } else {
        sessions.add(checkpoint);
      }
    }
    return SessionStore._(prefs, sessions);
  }

  static List<ClassSession> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(_decodePayload(raw)) as List<dynamic>;
      return list
          .map((e) => ClassSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static ClassSession? _decodeOne(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return ClassSession.fromJson(
          jsonDecode(_decodePayload(raw)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 按结束时间倒序（新的在前）。
  List<ClassSession> get sessions {
    final list = [..._sessions];
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  /// 保存（新增或更新）一条记录。
  Future<void> save(ClassSession s) => _enqueueSave(s, writeTextCopy: true);

  /// 听写运行中的轻量快照。只更新主存储，不反复覆写导出文本文件。
  Future<void> saveCheckpoint(ClassSession s) => _enqueueCheckpoint(s);

  Future<void> _enqueueSave(
    ClassSession session, {
    required bool writeTextCopy,
  }) {
    final snapshot = _normalizedSnapshot(session);
    return _enqueueWrite(() async {
      final idx = _sessions.indexWhere((x) => x.id == snapshot.id);
      if (idx >= 0) {
        _sessions[idx] = snapshot;
      } else {
        _sessions.add(snapshot);
      }
      await _persist();
      final checkpoint = _decodeOne(_prefs.getString(_checkpointKey));
      if (checkpoint?.id == snapshot.id) {
        await _prefs.remove(_checkpointKey);
      }
      if (writeTextCopy) await _writeTextCopy(snapshot);
    });
  }

  Future<void> _enqueueCheckpoint(ClassSession session) {
    final snapshot = _normalizedSnapshot(session);
    return _enqueueWrite(() async {
      final idx = _sessions.indexWhere((x) => x.id == snapshot.id);
      if (idx >= 0) {
        _sessions[idx] = snapshot;
      } else {
        _sessions.add(snapshot);
      }
      await _prefs.setString(
        _checkpointKey,
        _encodePayload(jsonEncode(snapshot.toJson())),
      );
    });
  }

  /// 所有本地写入共享一条不会被单次失败毒死的队列。
  /// 例如文本导出失败后，下一次 5 秒 checkpoint 仍然必须能继续落盘。
  Future<void> _enqueueWrite(Future<void> Function() action) {
    final operation = _writeTail.then<void>(
      (_) => action(),
      onError: (_, __) => action(),
    );
    _writeTail = operation;
    return operation;
  }

  static ClassSession _normalizedSnapshot(ClassSession s) {
    final title = SessionTitleInference.normalizeTitle(s.title, s.transcript);
    return ClassSession(
      id: s.id,
      title: title,
      courseName: s.courseName,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      transcript: s.transcript,
      events: AlertEventMerger.merge(s.events),
      summary: s.summary,
      language: s.language,
    );
  }

  Future<void> remove(String id) async {
    await _enqueueWrite(() async {
      _sessions.removeWhere((x) => x.id == id);
      await _persist();
      final checkpoint = _decodeOne(_prefs.getString(_checkpointKey));
      if (checkpoint?.id == id) await _prefs.remove(_checkpointKey);
      try {
        final dir = await _textDirectory();
        final file = File(p.join(dir.path, '$id.txt'));
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 文本副本清理失败不影响主记录删除。
      }
    });
  }

  Future<void> _persist() => _prefs.setString(
        _key,
        _encodePayload(jsonEncode(_sessions.map((s) => s.toJson()).toList())),
      );

  /// gzip 是 `dart:io` 内置能力，不增加 APK 依赖；前缀使旧版明文 JSON
  /// 可以无迁移脚本直接读取，并在下一次写入时自动压缩。
  static String _encodePayload(String json) {
    final compressed = gzip.encode(utf8.encode(json));
    return '$_compressedPrefix${base64Encode(compressed)}';
  }

  static String _decodePayload(String raw) {
    if (!raw.startsWith(_compressedPrefix)) return raw;
    try {
      final bytes = base64Decode(raw.substring(_compressedPrefix.length));
      return utf8.decode(gzip.decode(bytes));
    } catch (_) {
      // 让外层的 JSON 错误处理负责回退为空，不影响旧记录加载。
      return raw;
    }
  }

  Future<Directory> _textDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'iko_class_sessions'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _writeTextCopy(ClassSession session) async {
    try {
      final dir = await _textDirectory();
      final file = File(p.join(dir.path, '${session.id}.txt'));
      final events = session.events.isEmpty
          ? '无'
          : session.events
              .map((event) =>
                  '- ${event.timestamp.toLocal()} · ${event.type == AlertType.rollCall ? '点名' : '提问'} · ${event.triggerText}${event.question == null ? '' : ' · 问题：${event.question}'}')
              .join('\n');
      final content = [
        'IKO 课堂记录',
        '标题：${session.title}',
        '课程：${session.courseName}',
        '开始：${session.startedAt.toLocal()}',
        '结束：${session.endedAt?.toLocal() ?? '进行中'}',
        '时长：${session.duration.inSeconds} 秒',
        '',
        '预警事件：',
        events,
        '',
        if (session.summary?.trim().isNotEmpty == true) ...[
          'AI 摘要：',
          session.summary!.trim(),
          '',
        ],
        '课堂转写：',
        session.transcript,
      ].join('\n');
      await file.writeAsString(content, flush: true);
    } catch (_) {
      // SharedPreferences 仍是主存储；部分桌面测试环境没有 path_provider 实现。
    }
  }
}
