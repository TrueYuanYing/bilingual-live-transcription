import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ai_connection.dart';

/// 仅保存当前设备所有者的云端 AI 凭据。
///
/// Android 使用 Keystore 加密的 SharedPreferences，和普通 AppSettings 分离，
/// 不会出现在导出的设置 JSON、日志或 release APK 内。
class AiCredentialStore {
  AiCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                  encryptedSharedPreferences: true,
                  sharedPreferencesName: 'FlutterSecureStorage'),
            );

  static String storageKey(String provider) => provider == 'deepseek'
      ? 'iko.deepseek.owner_api_key'
      : 'iko.ai.$provider.owner_api_key';

  final FlutterSecureStorage _storage;

  Future<String> read({String provider = 'deepseek'}) async =>
      ((await _storage.read(key: storageKey(provider))) ?? '').trim();

  Future<bool> hasCredential({String provider = 'deepseek'}) async =>
      (await read(provider: provider)).isNotEmpty;

  Future<void> save(String value, {String provider = 'deepseek'}) async {
    final credential = value.trim();
    if (credential.isEmpty) {
      throw ArgumentError('云端 AI 密钥不能为空');
    }
    await AiSettingsWriteQueue.run(storageKey(provider),
        () => _storage.write(key: storageKey(provider), value: credential));
  }

  Future<void> clear({String provider = 'deepseek'}) =>
      AiSettingsWriteQueue.run(storageKey(provider),
          () => _storage.delete(key: storageKey(provider)));
}
