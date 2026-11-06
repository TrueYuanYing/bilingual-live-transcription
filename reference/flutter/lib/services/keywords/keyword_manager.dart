import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/keyword_pack.dart';
import 'builtin_keyword_packs.dart';

/// 关键词库管理器：管理启用的内置包 + 用户自定义关键词包，并持久化。
class KeywordManager {
  KeywordManager._(
      this._prefs, this._userPacks, this._enabledIds, this._selectedPackId);

  final SharedPreferences _prefs;
  final List<KeywordPack> _userPacks;
  final List<String> _enabledIds;
  String? _selectedPackId;

  static const _kEnabled = 'kw_enabled_ids';
  static const _kUserPacks = 'kw_user_packs';
  static const _kSelectedPack = 'kw_selected_pack_id';

  static Future<KeywordManager> load() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = List<String>.of(
      prefs.getStringList(_kEnabled) ?? BuiltInKeywordPacks.defaultEnabledIds(),
    );
    final userPacks = _decodeUserPacks(prefs.getString(_kUserPacks));
    return KeywordManager._(
        prefs, userPacks, enabled, prefs.getString(_kSelectedPack));
  }

  static List<KeywordPack> _decodeUserPacks(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => KeywordPack.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 当前全部生效的关键词包（内置已启用的 + 用户自定义全部）。
  List<KeywordPack> activePacks() {
    final active = <KeywordPack>[
      for (final p in BuiltInKeywordPacks.all)
        if (_enabledIds.contains(p.id)) p,
      ..._userPacks,
    ];
    return active;
  }

  /// 内置包是否被启用。
  bool isBuiltInEnabled(String id) => _enabledIds.contains(id);

  /// 当前课堂使用的词包，用于给 AI 提供学科语境。
  KeywordPack? get selectedPack {
    final id = _selectedPackId;
    if (id == null) return null;
    for (final pack in activePacks()) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  /// 选择当前课堂词包；选择内置词包时会自动启用它。
  Future<void> selectPack(String? id) async {
    if (id == null || id.isEmpty) {
      _selectedPackId = null;
      await _prefs.remove(_kSelectedPack);
      return;
    }
    if (BuiltInKeywordPacks.byId(id) != null && !_enabledIds.contains(id)) {
      _enabledIds.add(id);
      await _persistEnabled();
    }
    if (!activePacks().any((pack) => pack.id == id)) return;
    _selectedPackId = id;
    await _prefs.setString(_kSelectedPack, id);
  }

  /// 参考课程词库生成简短 AI 语境，只注入学科术语，避免消耗过多 token。
  String contextLine({int maxChars = 2000}) {
    final pack = selectedPack;
    if (pack == null) return '';
    final terms = pack.keywords
        .where((keyword) => keyword.enabled && keyword.kind == KeywordKind.term)
        .map((keyword) => keyword.text)
        .toList();
    if (terms.isEmpty) return '';
    final joined = terms.join('、');
    final clipped =
        joined.length > maxChars ? joined.substring(0, maxChars) : joined;
    return '本课为「${pack.name}」，课堂主题词汇：$clipped';
  }

  /// 切换内置包启用状态。
  Future<void> toggleBuiltIn(String id, bool enable) async {
    if (enable) {
      if (!_enabledIds.contains(id)) _enabledIds.add(id);
    } else {
      _enabledIds.remove(id);
      if (_selectedPackId == id) await selectPack(null);
    }
    await _persistEnabled();
  }

  /// 新增一个用户自定义关键词包。
  Future<KeywordPack> addUserPack(String name,
      {List<Keyword> keywords = const []}) async {
    final pack = KeywordPack(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      keywords: keywords,
      isBuiltIn: false,
    );
    _userPacks.add(pack);
    await _persistUserPacks();
    return pack;
  }

  /// 往指定用户包加关键词。
  Future<void> addKeyword(String packId, Keyword keyword) async {
    final pack = _userPacks.firstWhere((p) => p.id == packId);
    final idx = _userPacks.indexOf(pack);
    _userPacks[idx] = KeywordPack(
      id: pack.id,
      name: pack.name,
      keywords: [...pack.keywords, keyword],
      isBuiltIn: false,
    );
    await _persistUserPacks();
  }

  /// 从自定义词包移除指定关键词。
  Future<void> removeKeyword(String packId, Keyword keyword) async {
    final index = _userPacks.indexWhere((pack) => pack.id == packId);
    if (index < 0) return;
    final pack = _userPacks[index];
    _userPacks[index] = KeywordPack(
      id: pack.id,
      name: pack.name,
      keywords: [
        for (final item in pack.keywords)
          if (!identical(item, keyword)) item,
      ],
      isBuiltIn: false,
    );
    await _persistUserPacks();
  }

  /// 删除用户自定义包。
  Future<void> removeUserPack(String packId) async {
    _userPacks.removeWhere((p) => p.id == packId);
    if (_selectedPackId == packId) await selectPack(null);
    await _persistUserPacks();
  }

  Future<void> _persistEnabled() =>
      _prefs.setStringList(_kEnabled, _enabledIds);

  Future<void> _persistUserPacks() => _prefs.setString(
      _kUserPacks, jsonEncode(_userPacks.map((p) => p.toJson()).toList()));
}
