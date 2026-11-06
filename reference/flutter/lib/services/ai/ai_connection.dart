import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum AiProtocol { openAi, anthropic }

class AiProviderPreset {
  const AiProviderPreset(this.id, this.label, this.baseUrl, this.models,
      {this.protocol = AiProtocol.openAi, this.note = ''});
  final String id;
  final String label;
  final String baseUrl;
  final List<String> models;
  final AiProtocol protocol;
  final String note;

  AiConnection get connection => AiConnection(
      providerId: id,
      baseUrl: baseUrl,
      model: models.first,
      protocol: protocol);
}

const aiProviderPresets = [
  AiProviderPreset(
      'deepseek', 'DeepSeek', 'https://api.deepseek.com', ['deepseek-flash'],
      note: 'DeepSeek V4.1 Flash · 课堂快速回答'),
  AiProviderPreset(
      'doubao', '豆包 · 火山方舟', 'https://ark.cn-beijing.volces.com/api/v3', [''],
      note: '填入方舟控制台开通的模型 ID 或推理接入点 ep-…'),
  AiProviderPreset(
      'qwen',
      '千问 · 阿里云百炼',
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
      ['qwen-plus', 'qwen-turbo'],
      note: '密钥与地域需一致；也可填写业务空间专属 Base URL'),
  AiProviderPreset('zhipu', '智谱 · GLM', 'https://open.bigmodel.cn/api/paas/v4',
      ['glm-4.7-flash', 'glm-4-flash-250414'],
      note:
          '两款官方免费文本模型；4.7-Flash 繁忙时可选择 4-Flash-250414。需要自己的 API Key，价格以供应商为准'),
  AiProviderPreset('siliconflow', '硅基流动', 'https://api.siliconflow.cn/v1', [''],
      note: '获取账号可用模型，或手动填写完整模型 ID'),
  AiProviderPreset(
      'kimi', 'Moonshot · Kimi', 'https://api.moonshot.cn/v1', [''],
      note: '从账号可用模型选择，或填写控制台模型 ID'),
  AiProviderPreset('openai', 'OpenAI', 'https://api.openai.com/v1',
      ['gpt-4.1-mini', 'gpt-4.1']),
  AiProviderPreset(
      'gemini',
      'Google · Gemini',
      'https://generativelanguage.googleapis.com/v1beta/openai',
      ['gemini-flash-latest'],
      note: '使用 Google 官方 OpenAI 兼容接口'),
  AiProviderPreset(
      'claude', 'Anthropic · Claude', 'https://api.anthropic.com/v1', [''],
      protocol: AiProtocol.anthropic,
      note: '使用原生 Messages API；获取可用模型或填写准确模型 ID'),
  AiProviderPreset(
      'openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1', [''],
      note: '模型通常为供应商/模型名；以账号权限和计费规则为准'),
  AiProviderPreset('custom', '自定义兼容接口', '', [''],
      note: '支持 OpenAI Chat Completions 或 Anthropic Messages 协议'),
];

class AiConnection {
  const AiConnection(
      {this.providerId = 'deepseek',
      this.baseUrl = 'https://api.deepseek.com',
      this.model = 'deepseek-flash',
      this.protocol = AiProtocol.openAi});
  final String providerId;
  final String baseUrl;
  final String model;
  final AiProtocol protocol;

  AiProviderPreset get preset =>
      aiProviderPresets.firstWhere((p) => p.id == providerId,
          orElse: () => aiProviderPresets.last);

  Uri endpoint(String suffix) {
    final uri = Uri.tryParse(baseUrl.trim());
    final local = uri?.host == 'localhost' ||
        uri?.host == '127.0.0.1' ||
        uri?.host == '::1';
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      throw const FormatException('Base URL 需为 HTTPS 地址，不含密钥、查询参数或登录信息。');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    // 用户可粘贴完整端点，也可填写 SDK 的 Base URL。
    path =
        path.replaceFirst(RegExp(r'/(chat/completions|messages|models)$'), '');
    return uri.replace(path: '$path/$suffix');
  }

  void validate() {
    if (!aiProviderPresets.any((p) => p.id == providerId)) {
      throw const FormatException('请选择有效的供应商。');
    }
    endpoint('models');
    if (model.trim().isEmpty ||
        model.length > 200 ||
        RegExp(r'[\x00-\x1f]').hasMatch(model)) {
      throw const FormatException('请输入供应商提供的准确模型 ID。');
    }
  }

  Map<String, dynamic> toJson() => {
        'provider': providerId,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        'protocol': protocol.name
      };

  factory AiConnection.fromJson(Map<String, dynamic> json) => AiConnection(
        providerId: json['provider'] as String? ?? 'deepseek',
        baseUrl: json['baseUrl'] as String? ?? 'https://api.deepseek.com',
        model: json['model'] as String? ?? 'deepseek-flash',
        protocol: json['protocol'] == 'anthropic'
            ? AiProtocol.anthropic
            : AiProtocol.openAi,
      );
}

/// 只持久化非秘密连接信息；密钥由 AiCredentialStore 单独加密保存。
class AiConnectionStore {
  static const storageKey = 'iko.ai.connection.v1';
  Future<AiConnection> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return const AiConnection();
    try {
      final connection =
          AiConnection.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      connection.validate();
      return connection;
    } catch (_) {
      return const AiConnection();
    }
  }

  Future<void> save(AiConnection connection) async {
    connection.validate();
    await AiSettingsWriteQueue.run(storageKey, () async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(storageKey, jsonEncode(connection.toJson()))) {
        throw StateError('连接配置保存失败，请重试。');
      }
    });
  }
}

/// Future.timeout 无法撤销平台写入，按存储 key 串行提交，保证最后操作生效。
/// 队列跨页面/实例共享；完成即移除，不持有密钥。
class AiSettingsWriteQueue {
  static final _pending = <String, Future<void>>{};
  static Future<void> run(String key, Future<void> Function() write) {
    final operation =
        (_pending[key] ?? Future<void>.value()).then((_) => write());
    final settled = operation.then<void>((_) {}, onError: (Object _) {});
    _pending[key] = settled;
    unawaited(settled.whenComplete(() {
      if (identical(_pending[key], settled)) _pending.remove(key);
    }));
    return operation;
  }
}
