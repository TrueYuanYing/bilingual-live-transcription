import 'dart:io';
import 'bundled_model_sizes.dart';
import '../resources/resource_packages.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle, MethodChannel;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// sherpa-onnx 模型管理：原有模型按需安装到同一应用文档目录。
/// 支持多语种切换，每个语种一个子目录。
class ModelManager {
  ModelManager._(this._baseDir);

  final String _baseDir;

  /// 支持的语言 → assets 子目录。
  static const supportedLanguages = ['zh', 'en', 'auto'];

  /// 返回某个识别选项实际需要准备的模型目录。
  ///
  /// `auto` 只加载双语模型；保留 `null` 的全量行为兼容旧入口。
  static List<String> languagesRequiredFor(String? language) {
    if (language == null) return supportedLanguages;
    return switch (language) {
      'auto' => ['auto'],
      'en' => ['en'],
      _ => ['zh'],
    };
  }

  static const _modelFiles = [
    'tokens.txt',
    'encoder.int8.onnx',
    'decoder.onnx',
    'joiner.onnx',
  ];

  static List<String> _filesFor(String language) => language == 'auto'
      ? [..._modelFiles, 'model.int8.onnx', 'offline-tokens.txt']
      : _modelFiles;

  /// 打开一个指向固定目录的模型管理器。
  factory ModelManager.open(String dir) => ModelManager._(dir);

  /// 应用文档目录路径。
  static Future<String> resolveDirPath() async {
    if (kIsWeb) {
      return p.join('.', 'sherpa_models');
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'sherpa_models');
  }

  String get baseDir => _baseDir;

  /// 某语种的模型目录。
  String modelDirFor(String lang) => p.join(_baseDir, lang);

  /// 某语种模型是否已就绪。
  bool isReady(String lang) {
    final dir = modelDirFor(lang);
    return _filesFor(lang).every((f) {
      final file = File(p.join(dir, f));
      return file.existsSync() &&
          file.lengthSync() == bundledModelSizes['$lang/$f'];
    });
  }

  /// 复制模型到应用目录，回报进度(0~1)与消息。
  ///
  /// 传入 [language] 时只准备当前语种；未传入时保留旧的“准备全部”行为，
  /// 方便已有外部调用方平滑迁移。新 UI 默认按需加载，避免首次启动把三套
  /// encoder/decoder 全部复制到应用数据目录。
  Future<void> prepare({
    required void Function(double progress, String message) onProgress,
    String? language,
  }) async {
    if (kIsWeb) {
      onProgress(1.0, '预览模式');
      return;
    }
    await Directory(_baseDir).create(recursive: true);
    final languages = languagesRequiredFor(language);
    final total = languages.fold<int>(
        0, (count, language) => count + _filesFor(language).length);
    var done = 0;
    for (final lang in languages) {
      if (Platform.isAndroid) {
        {
          // Native verification adopts unchanged existing bytes without a network
          // request, and detects same-length corruption before the recognizer loads.
          final id = 'asr-$lang';
          final progress = resourcePackEvents.listen((dynamic event) {
            if (event is Map && event['id'] == id) {
              onProgress(((event['progress'] as num?)?.toDouble() ?? 0),
                  event['message'] as String? ?? '正在安装听写资源…');
            }
          }, onError: (Object _) {});
          try {
            await const MethodChannel('com.iko.study/resource_packs')
                .invokeMethod<dynamic>('download', {'id': id});
          } finally {
            await progress.cancel();
          }
          if (!isReady(lang)) throw StateError('模型安装未完成，请到“存储与资源”重试。原听写设置保留。');
        }
        done += _filesFor(lang).length;
        onProgress(done / total, '听写模型已就绪');
        continue;
      }
      for (final f in _filesFor(lang)) {
        final asset = 'assets/sherpa/$lang/$f';
        final target = File(p.join(modelDirFor(lang), f));
        await Directory(modelDirFor(lang)).create(recursive: true);
        if (target.existsSync() &&
            target.lengthSync() == bundledModelSizes['$lang/$f']) {
          done++;
          continue;
        }
        onProgress(done / total, '加载 $lang/$f…');
        {
          final bytes = await rootBundle.load(asset);
          if (bytes.lengthInBytes != bundledModelSizes['$lang/$f']) {
            throw StateError('模型资源不完整：$lang/$f');
          }
          final temporary = File('${target.path}.partial');
          await temporary.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true,
          );
          if (await target.exists()) await target.delete();
          await temporary.rename(target.path);
        }
        if (await target.length() != bundledModelSizes['$lang/$f']) {
          throw StateError('模型复制不完整：$lang/$f');
        }
        done++;
        onProgress(done / total, '$lang/$f 完成');
      }
    }
    onProgress(1.0, '模型就绪');
  }
}
