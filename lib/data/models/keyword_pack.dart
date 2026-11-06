/// 关键词库模型：按课程/专业组织的关键词包。
/// 关键词类型用于区分触发语义（点名 / 提问 / 普通学科术语）。
library;

/// 关键词的用途分类。
enum KeywordKind {
  /// 点名相关："点个名""提问""抽人" 等。
  rollCall,

  /// 提问相关："谁来说""为什么""举个例子" 等。
  question,

  /// 学科术语：仅记录高亮，不弹窗。
  term,
}

/// 一个关键词条目。
class Keyword {
  const Keyword({
    required this.text,
    required this.kind,
    this.enabled = true,
  });

  final String text;
  final KeywordKind kind;
  final bool enabled;

  Keyword copyWith({bool? enabled, KeywordKind? kind}) => Keyword(
        text: text,
        kind: kind ?? this.kind,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() =>
      {'text': text, 'kind': kind.name, 'enabled': enabled};

  factory Keyword.fromJson(Map<String, dynamic> j) => Keyword(
        text: j['text'] as String,
        kind: KeywordKind.values.byName(j['kind'] as String),
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// 一个关键词包：对应一门课或一个专业方向。
class KeywordPack {
  const KeywordPack({
    required this.id,
    required this.name,
    required this.keywords,
    this.isBuiltIn = false,
  });

  final String id;
  final String name;
  final List<Keyword> keywords;
  final bool isBuiltIn;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'keywords': keywords.map((k) => k.toJson()).toList(),
        'isBuiltIn': isBuiltIn,
      };

  factory KeywordPack.fromJson(Map<String, dynamic> j) => KeywordPack(
        id: j['id'] as String,
        name: j['name'] as String,
        keywords: ((j['keywords'] as List<dynamic>?) ?? [])
            .map((k) => Keyword.fromJson(k as Map<String, dynamic>))
            .toList(),
        isBuiltIn: j['isBuiltIn'] as bool? ?? false,
      );
}
