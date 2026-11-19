/// ORBAT 数据模型 + 7 键归一化 + 红牌校验
import 'schema_rules.dart';
import 'sidc_entities.dart';
import 'sidc_rule.dart';
import 'sidc_tables.dart';

/// 一个编制节点
class OrbatNode {
  final String uniqueDesignation; // 显示名（中文）
  final String additionalInformation; // 注释（≤24 汉字）
  final String sidc; // 30 位
  final List<OrbatNode> children;

  OrbatNode({
    required this.uniqueDesignation,
    required this.additionalInformation,
    required this.sidc,
    List<OrbatNode>? children,
  }) : children = children ?? <OrbatNode>[];

  /// 从渲染器/AI 产出的 JSON 解析
  factory OrbatNode.fromJson(Map<String, dynamic> json) {
    final opts = (json['options'] is Map) ? json['options'] as Map : const {};
    final subs = (json['subOrganizations'] is List)
        ? json['subOrganizations'] as List
        : const [];
    return OrbatNode(
      uniqueDesignation: (opts['uniqueDesignation'] ?? '').toString(),
      additionalInformation: (opts['additionalInformation'] ?? '').toString(),
      sidc: (opts['sidc'] ?? '').toString(),
      children: subs
          .whereType<Map>()
          .map((s) => OrbatNode.fromJson(Map<String, dynamic>.from(s)))
          .toList(),
    );
  }

  /// 转成渲染器要求的 7 键归一化结构
  ///
  /// [adaptForRender] = true 时才做渲染适配（括号内容移到注释、名称压到安全长度）。
  /// **导出/保存必须用 false**：用户存下来的 JSON 应当与识别结果逐字一致，
  /// 以前默认就适配，导致导出文件里的名称是被截断过的（v0.4 修正）。
  Map<String, dynamic> toNormalizedJson({
    required String commandLevels,
    bool adaptForRender = false,
  }) {
    final adapted = adaptForRender
        ? _adaptNameForRenderer(uniqueDesignation, additionalInformation)
        : (name: uniqueDesignation, note: additionalInformation);
    return {
      'options': {
        'sidc': sidc,
        'uniqueDesignation': adapted.name,
        'additionalInformation': adapted.note,
        'dashed': false,
        'outline': false,
        'plain-text-mode': false,
        'showMapLabels': true,
      },
      'subOrganizations': children
          .map((c) => c.toNormalizedJson(
              commandLevels: '', adaptForRender: adaptForRender))
          .toList(),
      // commandLevels 只出现在根节点，由外层统一加
    };
  }

  int get count => 1 + children.fold(0, (sum, c) => sum + c.count);

  int get maxDepth {
    if (children.isEmpty) return 1;
    return 1 + children.map((c) => c.maxDepth).reduce((a, b) => a > b ? a : b);
  }
}

/// 渲染适配后的名称与注释。
/// 线上渲染器对超长 uniqueDesignation 会卡在画布渲染阶段（实测英文全名+驻地
/// 30+ 字符必现），所以渲染前统一：括号内容移到注释、名称压到安全长度。
({String name, String note}) _adaptNameForRenderer(String name, String note) {
  var n = name.trim();
  var extra = '';

  // 1) 尾部括号内容（驻地/原名）移到注释。支持连续多个括号。
  final tail = RegExp(r'\s*(\(([^()]{1,40})\))\s*$');
  for (var i = 0; i < 2; i++) {
    final m = tail.firstMatch(n);
    if (m == null) break;
    final inner = m.group(2)!.trim();
    if (inner.isNotEmpty) {
      extra = extra.isEmpty ? inner : '$extra·$inner';
    }
    n = n.substring(0, m.start).trim();
  }

  // 2) 名称压到安全长度（按字符数；中文/英文一视同仁）
  const maxName = 26;
  if (n.length > maxName) n = '${n.substring(0, maxName - 1)}…';

  // 3) 合并注释（原注释 + 括号里的内容），按渲染器上限截断
  var merged = [note.trim(), extra].where((s) => s.isNotEmpty).join(' · ');
  const maxNote = 48;
  if (merged.length > maxNote) merged = '${merged.substring(0, maxNote - 1)}…';

  return (name: n.isEmpty ? name.trim() : n, note: merged);
}

/// 归一化后的完整树（带根 commandLevels）
///
/// [adaptForRender] 默认 false（保真）。只有真正送给线上渲染器时才传 true。
Map<String, dynamic> normalizeTree(OrbatNode root,
    {required String commandLevels, bool adaptForRender = false}) {
  final json = root.toNormalizedJson(
      commandLevels: commandLevels, adaptForRender: adaptForRender);
  json['commandLevels'] = commandLevels;
  return json;
}

/// 校验结果
class ValidationIssue {
  final String level; // 'red' 红牌必须修 / 'warn' 软警告
  final String path; // 节点路径
  final String message;

  ValidationIssue(this.level, this.path, this.message);

  @override
  String toString() => '[$level] $path: $message';
}

/// 红牌校验器 —— 移植 skill 的命名铁律与 SIDC 规则
class OrbatValidator {
  static ValidationReport validate(OrbatNode root) {
    final issues = <ValidationIssue>[];
    _checkNode(root, '根', issues, 1);

    // 全局规则
    if (root.count > 80) {
      issues.add(ValidationIssue('warn', '全局',
          '节点总数 ${root.count} > 80，建议合并无编号重复单位'));
    }
    final depth = root.maxDepth;
    if (depth > 3) {
      issues.add(ValidationIssue('warn', '全局',
          '最大层级 $depth > 3，第 3 层以下不应展开'));
    }

    return ValidationReport(issues: issues, nodeCount: root.count, depth: depth);
  }

  static void _checkNode(OrbatNode node, String path, List<ValidationIssue> issues,
      int depth,
      {String? parentEchelon, String? parentName}) {
    // SIDC 长度与格式
    if (node.sidc.length != 30) {
      issues.add(ValidationIssue(
          'red', path, 'SIDC 必须 30 位，当前 ${node.sidc.length} 位: ${node.sidc}'));
    } else if (!RegExp(r'^\d+$').hasMatch(node.sidc)) {
      issues.add(ValidationIssue('red', path, 'SIDC 含非数字字符'));
    } else {
      // 版本位
      if (node.sidc.substring(0, 2) != '13') {
        issues.add(ValidationIssue('red', path, 'SIDC 版本位应为 13'));
      }
      // 保留位（前缀8 + 梯队2 + 主实体6 + 修饰6 = 22，之后 8 位保留）
      if (node.sidc.substring(22) != '00000000') {
        issues.add(ValidationIssue('red', path, 'SIDC 保留位(23-30)应为 00000000'));
      }
      // 梯队码合法性（位 9-10，0-based 8-10）
      final echelon = node.sidc.substring(8, 10);
      if (!kEchelon.containsKey(echelon) && echelon != '00') {
        issues.add(ValidationIssue(
            'red', path, '梯队码 $echelon 非法（19/20 禁用，见码表）'));
      }
      // 符号集（0-based 4-6）：10=陆地, 01=空中。主实体码语义随符号集变化。
      final symbolSet = node.sidc.substring(4, 6);
      // 主实体码（0-based 10-16）
      final entity = node.sidc.substring(10, 16);
      // 用 milsymbol 全量表判定合法性（渲染器真正认的表）
      final table = switch (symbolSet) {
        '10' => kLandEntityFull,
        '01' => kAirEntityFull,
        _ => null,
      };
      // 000000 是项目约定的"通用/无兵种标志"，标准表中不存在但合法，放行。
      if (entity != '000000') {
        if (table != null) {
          if (!table.containsKey(entity)) {
            issues.add(ValidationIssue('warn', path,
                '主实体码 $entity 不在符号集 $symbolSet 标准表中，请用 sidc.js meta 查证'));
          }
        } else if (!kEntity.containsKey(entity)) {
          issues.add(ValidationIssue(
              'warn', path, '符号集 $symbolSet 未支持，主实体码 $entity 未核对'));
        }
      }
      // 110000 禁用 mod 98（类型修饰位 0-based 16-18）
      final typeMod = node.sidc.substring(16, 18);
      if (entity == '110000' && typeMod == '98') {
        issues.add(ValidationIssue(
            'red', path, '110000(HQ) 禁止加类型修饰 98，会导致整棵子树渲染消失'));
      }

      // ---- 结构自洽四查（v0.4 / A2）----
      // 这四条以前只能靠人眼在树视图里翻：码在表里"合法"，图却画错。

      // ① 层级倒挂：子节点梯队高于父节点（营下挂旅），图上结构必错
      final rank = _echelonRank[echelon];
      final parentRank = _echelonRank[parentEchelon];
      if (rank != null && parentRank != null && rank > parentRank) {
        issues.add(ValidationIssue('red', path,
            '层级倒挂：本级梯队 $echelon 高于上级「${parentName ?? "?"}」的 $parentEchelon'));
      }

      // ② 名称层级词与梯队码不一致（名字写"营"，码给"连"）
      final nameEch = SidcRule.guessEchelon(node.uniqueDesignation);
      if (nameEch != '00' && echelon != '00' && nameEch != echelon) {
        // 例外：上级「XX部」按惯例低一级（旅部用连级 15），名称推断已处理，
        // 这里只对"明显差两级以上"或非 HQ 情况报警，减少噪音
        final isHqNode = node.uniqueDesignation.endsWith('部');
        if (!isHqNode) {
          issues.add(ValidationIssue('warn', path,
              '名称层级词对应 $nameEch，但 SIDC 梯队段是 $echelon（「${node.uniqueDesignation}」）'));
        }
      }

      // ③ 空中单位必须用符号集 01（直升机/无人机/各类固定翼）
      // 例外：陆军航空兵（120600）是地面建制，用符号集 10 是对的
      final looksAir = RegExp(
              r'直升机|无人机|运输机|战斗机|攻击机|轰炸机|加油机|教练机|预警机|侦察机|飞行'
              r'|helicopter|drone|\buav\b|aircraft|fighter|bomber|transport aircraft',
              caseSensitive: false)
          .hasMatch(node.uniqueDesignation);
      final isArmyAviation =
          RegExp(r'航空兵|陆航|陆军航空').hasMatch(node.uniqueDesignation);
      if (looksAir && !isArmyAviation && symbolSet == '10') {
        issues.add(ValidationIssue('red', path,
            '「${node.uniqueDesignation}」是空中单位，符号集应为 01，当前是 10（会渲染成方块）'));
      }
      if (!looksAir && symbolSet == '01') {
        issues.add(ValidationIssue('warn', path,
            '符号集为 01（空中），但名称「${node.uniqueDesignation}」不像空中单位'));
      }
    }

    // 命名铁律
    final name = node.uniqueDesignation;
    if (name.trim().isEmpty) {
      issues.add(ValidationIssue('red', path, 'uniqueDesignation 不能为空'));
    }
    // 空格+左括号 会让线上渲染器卡死
    if (RegExp(r'\s+\(').hasMatch(name)) {
      issues.add(ValidationIssue(
          'red', path, '名称含「空格+左括号」，会导致渲染器卡死；改为紧贴括号或用·分隔'));
    }
    // 「×N」合并写法：营级及以上不应合并（这些单位各有番号/装备/驻地），
    // 连、排级同构单位合并是允许的，与渲染器的排布策略无关。
    if (RegExp(r'[×xX]\s*\d+').hasMatch(name)) {
      final ech = node.sidc.length >= 10 ? node.sidc.substring(8, 10) : '';
      const battalionOrAbove = {'16', '17', '18', '21', '22', '23', '24', '25'};
      if (battalionOrAbove.contains(ech)) {
        issues.add(ValidationIssue(
            'warn', path, '「$name」是营级及以上单位却用了 ×N 合并，'
                '这些单位各有番号/装备/驻地，应逐个展开'));
      }
    }
    // 单个节点的直属子元素过多时，渲染器会折行，横向观感被拉宽
    if (node.children.length > 10) {
      issues.add(ValidationIssue(
          'warn', path, '「$name」有 ${node.children.length} 个直属下属，'
              '超过 10 个渲染器会折行，建议确认是否需要分层'));
    }
    // 注释长度（v0.4 新规：3 个中文词语 ≈ 12 汉字 / 20 字母）
    final note = node.additionalInformation;
    final usage = measureNote(note);
    if (!usage.ok) {
      issues.add(ValidationIssue('red', path,
          '注释超长：${usage.cjk} 汉字（上限 $kNoteMaxCjk）/ '
          '${usage.letters} 字母（上限 $kNoteMaxLetters）'));
    }
    // 指挥官姓名（粗检："师长XXX"这类）——软警告
    if (kCommanderPattern.hasMatch(note)) {
      issues.add(ValidationIssue('warn', path, '注释疑似含指挥官姓名，应移除'));
    }
    // 注释里塞了自检说明（质量备注不是数据）
    if (kSelfCheckNotePattern.hasMatch(note)) {
      issues.add(ValidationIssue(
          'warn', path, '注释含自检说明（应清空，质量备注不写进数据字段）'));
    }

    // 同父兄弟重名/前缀重复：提示词铁律第 8 条要求了，这里补上机器检查
    final seen = <String>[];
    for (final c in node.children) {
      final n = c.uniqueDesignation.trim();
      if (n.isEmpty) continue;
      if (seen.contains(n)) {
        issues.add(ValidationIssue(
            'red', '$path/$n', '同一父节点下出现同名子节点「$n」，会画成两个重复单位'));
      } else {
        for (final prev in seen) {
          if (prev.length >= 4 &&
              n.length >= 4 &&
              !prev.endsWith('部') &&
              !n.endsWith('部') &&
              (prev.startsWith(n) || n.startsWith(prev))) {
            issues.add(ValidationIssue('warn', '$path/$n',
                '「$n」与兄弟「$prev」名称互为前缀，疑似同一单位被识别两次'));
            break;
          }
        }
        seen.add(n);
      }
    }

    final selfEchelon = node.sidc.length >= 10 ? node.sidc.substring(8, 10) : null;
    for (var i = 0; i < node.children.length; i++) {
      _checkNode(node.children[i], '$path/${node.children[i].uniqueDesignation}',
          issues, depth + 1,
          parentEchelon: selfEchelon, parentName: node.uniqueDesignation);
    }
  }

  /// 梯队码秩（用于判断层级倒挂）。数字越大层级越高。
  static const Map<String, int> _echelonRank = {
    '11': 1, // 组/车组
    '12': 2, // 班
    '13': 3, // 组/小队
    '14': 4, // 排
    '15': 5, // 连
    '16': 6, // 营
    '17': 7, // 团
    '18': 8, // 旅
    '21': 9, // 师
    '22': 10, // 军
    '23': 11, // 集团军
    '24': 12, // 方面军
    '25': 13, // 战区
    '26': 14, // 总指挥部
  };
}

class ValidationReport {
  final List<ValidationIssue> issues;
  final int nodeCount;
  final int depth;

  ValidationReport({required this.issues, required this.nodeCount, required this.depth});

  int get redCount => issues.where((i) => i.level == 'red').length;
  int get warnCount => issues.where((i) => i.level == 'warn').length;
  bool get ok => redCount == 0;

  @override
  String toString() {
    final buf = StringBuffer();
    buf.writeln('节点 $nodeCount｜层级 $depth｜红牌 $redCount｜软警告 $warnCount');
    for (final issue in issues) {
      buf.writeln('  $issue');
    }
    return buf.toString();
  }
}
