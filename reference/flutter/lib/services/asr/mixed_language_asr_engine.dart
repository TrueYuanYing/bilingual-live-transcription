import 'sherpa_asr_engine.dart';

/// 同一套双语声学模型在句内识别中英文，共用一条 partial/final 时间线。
/// 保留已有入口，加载和解码仍由 Sherpa 工作线程负责。
class MixedLanguageAsrEngine extends SherpaAsrEngine {
  MixedLanguageAsrEngine({required super.baseDir}) : super(language: 'auto');

  void setBaseDir(String path) => baseDir = path;

  @override
  void setLanguage(String lang) => super.setLanguage('auto');
}
