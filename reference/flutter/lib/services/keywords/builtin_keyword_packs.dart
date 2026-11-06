import '../../data/models/keyword_pack.dart';

/// 预置关键词包：按常见课程/专业内置，供用户一键启用。
/// 每个包含点名/提问触发词 + 学科术语。可被用户增删。
class BuiltInKeywordPacks {
  BuiltInKeywordPacks._();

  static const List<KeywordPack> all = [
    KeywordPack(
      id: 'builtin_math',
      name: '数学 / 高数',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '抽人回答', kind: KeywordKind.rollCall),
        Keyword(text: '提问', kind: KeywordKind.question),
        Keyword(text: '谁来做', kind: KeywordKind.question),
        Keyword(text: '极限', kind: KeywordKind.term),
        Keyword(text: '导数', kind: KeywordKind.term),
        Keyword(text: '积分', kind: KeywordKind.term),
        Keyword(text: '微分', kind: KeywordKind.term),
        Keyword(text: '泰勒展开', kind: KeywordKind.term),
        Keyword(text: '矩阵', kind: KeywordKind.term),
        Keyword(text: '特征值', kind: KeywordKind.term),
        Keyword(text: '证明', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_english',
      name: '大学英语 / 外语',
      isBuiltIn: true,
      keywords: [
        Keyword(text: 'roll call', kind: KeywordKind.rollCall),
        Keyword(text: 'anyone', kind: KeywordKind.question),
        Keyword(text: 'who can', kind: KeywordKind.question),
        Keyword(text: 'translate', kind: KeywordKind.question),
        Keyword(text: 'how are you', kind: KeywordKind.term),
        Keyword(text: 'what does it mean', kind: KeywordKind.question),
        Keyword(text: 'paraphrase', kind: KeywordKind.question),
        Keyword(text: 'pronunciation', kind: KeywordKind.term),
        Keyword(text: 'context', kind: KeywordKind.term),
        Keyword(text: 'paragraph', kind: KeywordKind.term),
        Keyword(text: 'comprehension', kind: KeywordKind.term),
        Keyword(text: 'grammar', kind: KeywordKind.term),
        Keyword(text: 'vocabulary', kind: KeywordKind.term),
        Keyword(text: 'tense', kind: KeywordKind.term),
      ],
    ),
    KeywordPack(
      id: 'builtin_physics',
      name: '物理',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '抽人', kind: KeywordKind.rollCall),
        Keyword(text: '受力分析', kind: KeywordKind.term),
        Keyword(text: '牛顿', kind: KeywordKind.term),
        Keyword(text: '动量', kind: KeywordKind.term),
        Keyword(text: '能量守恒', kind: KeywordKind.term),
        Keyword(text: '电场', kind: KeywordKind.term),
        Keyword(text: '磁场', kind: KeywordKind.term),
        Keyword(text: '公式推导', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_programming',
      name: '计算机 / 编程',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '抽人', kind: KeywordKind.rollCall),
        Keyword(text: '谁来敲', kind: KeywordKind.question),
        Keyword(text: '算法', kind: KeywordKind.term),
        Keyword(text: '复杂度', kind: KeywordKind.term),
        Keyword(text: '递归', kind: KeywordKind.term),
        Keyword(text: '数据结构', kind: KeywordKind.term),
        Keyword(text: '面向对象', kind: KeywordKind.term),
        Keyword(text: '编译', kind: KeywordKind.term),
        Keyword(text: '报错', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_generic',
      name: '通用（默认）',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '点名', kind: KeywordKind.rollCall),
        Keyword(text: '抽查', kind: KeywordKind.rollCall),
        Keyword(text: '考勤', kind: KeywordKind.rollCall),
        Keyword(text: '提问', kind: KeywordKind.question),
        Keyword(text: '谁来回答', kind: KeywordKind.question),
        Keyword(text: '请同学回答', kind: KeywordKind.question),
        Keyword(text: '要点', kind: KeywordKind.term),
        Keyword(text: '重点', kind: KeywordKind.term),
        Keyword(text: '考点', kind: KeywordKind.term),
        Keyword(text: '作业', kind: KeywordKind.term),
        Keyword(text: '考试', kind: KeywordKind.term),
      ],
    ),
    KeywordPack(
      id: 'builtin_chemistry',
      name: '化学',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '化学反应', kind: KeywordKind.term),
        Keyword(text: '氧化还原', kind: KeywordKind.term),
        Keyword(text: '平衡常数', kind: KeywordKind.term),
        Keyword(text: '摩尔', kind: KeywordKind.term),
        Keyword(text: '滴定', kind: KeywordKind.term),
        Keyword(text: '方程式', kind: KeywordKind.question),
      ],
    ),
    // ===== 大学常见「水课」词包 =====
    KeywordPack(
      id: 'builtin_politics',
      name: '思政课（马原/毛概/思修/史纲）',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '抽人', kind: KeywordKind.rollCall),
        Keyword(text: '马克思主义', kind: KeywordKind.term),
        Keyword(text: '唯物辩证法', kind: KeywordKind.term),
        Keyword(text: '矛盾', kind: KeywordKind.term),
        Keyword(text: '实践', kind: KeywordKind.term),
        Keyword(text: '价值观', kind: KeywordKind.term),
        Keyword(text: '生产力', kind: KeywordKind.term),
        Keyword(text: '中国特色社会主义', kind: KeywordKind.term),
        Keyword(text: '历史', kind: KeywordKind.term),
        Keyword(text: '谈谈看法', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_general_edu',
      name: '通识水课（心理/就业/军理/创业）',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '抽查', kind: KeywordKind.rollCall),
        Keyword(text: '心理健康', kind: KeywordKind.term),
        Keyword(text: '情绪', kind: KeywordKind.term),
        Keyword(text: '职业规划', kind: KeywordKind.term),
        Keyword(text: '简历', kind: KeywordKind.term),
        Keyword(text: '面试', kind: KeywordKind.term),
        Keyword(text: '国防', kind: KeywordKind.term),
        Keyword(text: '军事', kind: KeywordKind.term),
        Keyword(text: '创业', kind: KeywordKind.term),
        Keyword(text: '创新', kind: KeywordKind.term),
        Keyword(text: '说说感受', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_literature',
      name: '大学语文 / 文学鉴赏',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点个名', kind: KeywordKind.rollCall),
        Keyword(text: '抽人', kind: KeywordKind.rollCall),
        Keyword(text: '作者', kind: KeywordKind.term),
        Keyword(text: '主题思想', kind: KeywordKind.term),
        Keyword(text: '修辞', kind: KeywordKind.term),
        Keyword(text: '意象', kind: KeywordKind.term),
        Keyword(text: '读后感', kind: KeywordKind.question),
        Keyword(text: '赏析', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_biology',
      name: '生物 / 医学基础',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点名', kind: KeywordKind.rollCall),
        Keyword(text: '细胞', kind: KeywordKind.term),
        Keyword(text: '基因表达', kind: KeywordKind.term),
        Keyword(text: '遗传', kind: KeywordKind.term),
        Keyword(text: '代谢', kind: KeywordKind.term),
        Keyword(text: '免疫', kind: KeywordKind.term),
        Keyword(text: '实验结果', kind: KeywordKind.question),
        Keyword(text: '机制', kind: KeywordKind.question),
      ],
    ),
    KeywordPack(
      id: 'builtin_economics',
      name: '经济 / 管理',
      isBuiltIn: true,
      keywords: [
        Keyword(text: '点名', kind: KeywordKind.rollCall),
        Keyword(text: '供给', kind: KeywordKind.term),
        Keyword(text: '需求', kind: KeywordKind.term),
        Keyword(text: '边际成本', kind: KeywordKind.term),
        Keyword(text: '机会成本', kind: KeywordKind.term),
        Keyword(text: '通货膨胀', kind: KeywordKind.term),
        Keyword(text: '商业模式', kind: KeywordKind.term),
        Keyword(text: '分析案例', kind: KeywordKind.question),
      ],
    ),
  ];

  /// 按 id 取包。
  static KeywordPack? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 默认启用的包（通用 + 数学）。
  static List<String> defaultEnabledIds() =>
      const ['builtin_generic', 'builtin_math'];
}
