import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../services/recording/classroom_recording.dart';

String recordingTime(Duration value) {
  final seconds = value.inSeconds;
  final minutes = seconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String recordingSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
        ? '${(bytes / 1024).toStringAsFixed(1)} KB'
        : '${(bytes / 1048576).toStringAsFixed(1)} MB';

/// Rebuilds independently at 1Hz; PCM events do not rebuild the transcript.
class ClassroomRecordingControl extends ConsumerWidget {
  const ClassroomRecordingControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(classroomRecordingProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
              recording.recording
                  ? Icons.fiber_manual_record_rounded
                  : Icons.mic_none_rounded,
              size: 18,
              color: recording.recording
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    recording.recording
                        ? '正在保存录音 · ${recordingTime(recording.duration)}'
                        : '保存课堂录音',
                    style: theme.textTheme.labelLarge),
                Text(
                    !recording.available
                        ? '系统增强暂不支持录音，听写不受影响'
                        : recording.recording
                            ? '${recording.format} · ${recordingSize(recording.bytes)} · 仅本机'
                            : '默认关闭 · 仅本机保存 · 不使用 API',
                    style: theme.textTheme.bodySmall),
              ])),
          PopupMenuButton<int>(
            tooltip: '录音音质',
            enabled: !recording.recording && recording.available,
            initialValue: recording.bitrate,
            onSelected: recording.setBitrate,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value:8000,checked:recording.bitrate==8000,child:const Text('省空间 · 8 kbps')),
              CheckedPopupMenuItem(
                  value: 16000,
                  checked: recording.bitrate == 16000,
                  child: const Text('较高音质 · 16 kbps')),
              CheckedPopupMenuItem(
                  value: 12000,
                  checked: recording.bitrate == 12000,
                  child: const Text('推荐音质 · 12 kbps')),
            ],
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Text(recording.bitrate == 8000 ? '省空间' : recording.bitrate == 16000?'较高':'推荐',
                    style: theme.textTheme.labelMedium)),
          ),
          Switch.adaptive(
            value: recording.enabled && recording.available,
            onChanged: recording.available ? recording.setEnabled : null,
          ),
        ]),
        if (recording.error != null)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(recording.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error))),
      ]),
    );
  }
}

class ClassroomRecordingPlayer extends ConsumerStatefulWidget {
  const ClassroomRecordingPlayer({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<ClassroomRecordingPlayer> createState() =>
      _ClassroomRecordingPlayerState();
}

class _ClassroomRecordingPlayerState
    extends ConsumerState<ClassroomRecordingPlayer> {
  Timer? _timer;
  String? _selected, _error;
  bool _playing = false, _polling = false, _busy = false;
  int _position = 0, _duration = 0;
  late ClassroomRecording _recording;

  @override
  void initState() {
    super.initState();
    _recording = ref.read(classroomRecordingProvider);
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_recording.stopPlayback().catchError((Object _) {}));
    super.dispose();
  }

  List<RecordingClip> get _clips =>
      _recording.clips.where((c) => c.session.id == widget.sessionId).toList();

  Future<void> _play(RecordingClip clip) async {
    try {
      if (_selected == clip.id && _playing) {
        await _recording.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      await _recording.play(clip.id);
      if (!mounted) return;
      setState(() {
        _selected = clip.id;
        _error = null;
      });
      _timer ??=
          Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
      await _poll();
    } catch (e) {
      if (mounted) setState(() => _error = '请结束听写后回放；若录音不完整，可尝试导出。');
    }
  }

  Future<void> _poll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final state = await _recording.player();
      if (!mounted) return;
      if (state['clipId'] != _selected) {
        _timer?.cancel();
        _timer = null;
        setState(() {
          _selected = null;
          _playing = false;
        });
        return;
      }
      final playing = state['playing'] == true;
      final position = state['positionMs'] as int? ?? 0;
      final duration = state['durationMs'] as int? ?? 0;
      final completed =
          _playing && !playing && duration > 0 && position >= duration - 300;
      setState(() {
        _playing = playing;
        _position = position;
        _duration = duration;
      });
      if (completed) {
        final clips = _clips;
        final index = clips.indexWhere((c) => c.id == _selected);
        if (index >= 0 && index + 1 < clips.length) {
          await _play(clips[index + 1]);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '回放暂不可用，请重新打开记录');
    } finally {
      _polling = false;
    }
  }

  Future<void> _share(List<RecordingClip> clips) async {
    final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('分享课堂录音'),
              children: [
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text('发送原文件，保留音质。QQ／微信的接收和播放能力取决于其版本；原录音始终保留。')),
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, 'com.tencent.mm'),
                    child: const Text('微信 · 作为文件')),
                SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(context, 'com.tencent.mobileqq'),
                    child: const Text('QQ · 作为文件')),
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, 'system'),
                    child: const Text('系统更多 · 原文件')),
              ],
            ));
    if (selected == null) return;
    try {
      await _recording.share(clips.map((clip) => clip.id).toList(),
          target: selected == 'system' ? null : selected);
    } catch (_) {
      if (mounted) {
        await _notice('暂时无法分享', '请先结束听写和录音，并确认已安装对应应用；也可选择系统更多或保存文件。');
      }
    }
  }

  Future<void> _export(RecordingClip clip) async {
    setState(() => _busy = true);
    try {
      final saved = await _recording.export(clip.id);
      if (saved && mounted) await _notice('录音已导出', '已保存到你选择的位置。');
    } catch (_) {
      if (mounted) await _notice('导出失败', '请选择可写入的位置后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md)),
              title: const Text('删除本节录音？'),
              content: const Text('仅删除这节课的本机音频，课堂文字、预警与摘要会保留。已导出的文件需单独删除。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除录音'))
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _recording.stopPlayback();
      await _recording.deleteSession(widget.sessionId);
      if (mounted) {
        setState(() {
          _selected = null;
          _playing = false;
        });
      }
    } catch (_) {
      if (mounted) await _notice('暂时无法删除', '请先停止这节课的录音，再重新操作。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _notice(String title, String message) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md)),
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'))
            ],
          ));

  @override
  Widget build(BuildContext context) {
    ref.watch(classroomRecordingProvider.select((r) => r.clips));
    final clips = _clips;
    if (clips.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final totalBytes = clips.fold<int>(0, (sum, c) => sum + c.bytes);
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: AppColors.fill(theme.brightness),
          borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.graphic_eq_rounded, size: 20),
          const SizedBox(width: 8),
          Expanded(
              child: Text('课堂录音 · ${recordingSize(totalBytes)}',
                  style: theme.textTheme.titleSmall)),
          if (clips.length > 1)
            IconButton(
                tooltip: '分享全部录音段',
                onPressed: _busy ? null : () => _share(clips),
                icon: const Icon(Icons.share_rounded, size: 20)),
          IconButton(
              tooltip: '仅删除录音',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded, size: 20))
        ]),
        Text('保存在本机 · 每 5 分钟一段 · 自动连续回放', style: theme.textTheme.bodySmall),
        for (var i = 0; i < clips.length; i++) ...[
          Row(children: [
            IconButton(
                tooltip: _playing && _selected == clips[i].id ? '暂停录音' : '回放录音',
                onPressed: _busy ? null : () => _play(clips[i]),
                icon: Icon(_playing && _selected == clips[i].id
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded)),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('第 ${i + 1} 段 · ${recordingTime(clips[i].duration)}',
                      style: theme.textTheme.bodyMedium),
                  Text(
                      '${clips[i].format} · ${recordingSize(clips[i].bytes)}${clips[i].complete ? '' : ' · 意外中断，可能不完整'}',
                      style: theme.textTheme.bodySmall),
                ])),
            IconButton(
                tooltip: '分享第 ${i + 1} 段到 QQ 或微信',
                onPressed: _busy ? null : () => _share([clips[i]]),
                icon: const Icon(Icons.share_rounded, size: 20)),
            IconButton(
                tooltip: '导出第 ${i + 1} 段',
                onPressed: _busy ? null : () => _export(clips[i]),
                icon: const Icon(Icons.save_alt_rounded, size: 20)),
          ]),
          if (_selected == clips[i].id && _duration > 0)
            Row(children: [
              Text(recordingTime(Duration(milliseconds: _position)),
                  style: theme.textTheme.labelSmall),
              Expanded(
                  child: Slider(
                      value: _position.clamp(0, _duration).toDouble(),
                      max: _duration.toDouble(),
                      onChanged: (value) =>
                          setState(() => _position = value.round()),
                      onChangeEnd: (value) => _recording.seek(value.round()))),
              Text(recordingTime(Duration(milliseconds: _duration)),
                  style: theme.textTheme.labelSmall)
            ]),
        ],
        if (_error != null)
          Text(_error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
      ]),
    );
  }
}
