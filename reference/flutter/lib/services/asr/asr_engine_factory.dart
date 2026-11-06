import 'asr_engine.dart';
import 'android_system_speech_asr_engine.dart';
import 'mixed_language_asr_engine.dart';
import 'sherpa_asr_engine.dart';

/// 创建与用户选择一致的本地 ASR 引擎。
///
/// `auto` 使用共享词表的中英双语模型，保留句内语言切换。
AsrEngine createAsrEngine({
  required String baseDir,
  required String language,
  String backend = 'local',
}) {
  final normalized = switch (language) {
    'en' => 'en',
    'auto' => 'auto',
    _ => 'zh',
  };

  if (backend == 'system') {
    return AndroidSystemSpeechAsrEngine(language: normalized);
  }

  if (normalized == 'auto') {
    return MixedLanguageAsrEngine(baseDir: baseDir);
  }
  return SherpaAsrEngine(baseDir: baseDir, language: normalized);
}
