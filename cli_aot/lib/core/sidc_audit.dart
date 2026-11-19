/// SIDC 一致性审计 —— 用本地规则引擎交叉核对模型给的 30 位码
///
/// 为什么需要（v0.4 / A1）：
///   项目里一直有两套 SIDC 来源——模型按提示词"逐段拼接"，本地 `SidcRule`
///   按名称关键词推导。但图像链路只信任模型，从不核对。于是会出现
///   「名字写营、梯队码给连」「直升机用陆地符号集」这类**看起来正常、其实错**的结果：
///   码在码表里合法，校验器放行，图照出，用户很难发现。
///
/// 本模块只做两件事，都是纯本地、零 API：
///   1. `run()`   —— 列出模型值与本地规则冲突的地方（供 UI 问题清单）
///   2. `apply()` —— 按既定优先级修正（名称层级词 > 模型梯队码；兵种关键词 > 模型实体码）
///
/// 裁决为什么这样定：
///   · 梯队：名称里的"师/旅/营/连"是图上直接读到的字，比模型拼的两位数字可信；
///   · 兵种：名称里的"反坦克/迫击炮/防空"同样是读到的词，而模型可能给通用码糊弄；
///   · 符号集：名称出现"直升机/无人机"就一定是空中（陆军航空兵除外，另有豁免）；
///   · 其余位（类型/机动/扇区修饰）本地推得不如模型细，一律保留模型值。
library;

import 'orbat.dart';
import 'sidc.dart';
import 'sidc_rule.dart';

enum AuditKind {
  echelon, // 梯队段不一致
  arm, // 主实体段不一致
  symbolSet, // 符号集（空中/地面）不一致
}

class AuditIssue {
  final String path;
  final String name;
  final AuditKind kind;

  /// 模型原值（30 位）
  final String modelSidc;

  /// 建议值（30 位）
  final String suggestedSidc;

  /// 人话说明，直接进问题清单
  final String reason;

  const AuditIssue({
    required this.path,
    required this.name,
    required this.kind,
    required this.modelSidc,
    required this.suggestedSidc,
    required this.reason,
  });

  @override
  String toString() => '[$path] $reason';
}

class SidcAudit {
  /// 审计整棵树，返回需要人工/自动处理的不一致项
  static List<AuditIssue> run(OrbatNode root) {
    final issues = <AuditIssue>[];
    _walk(root, '根', issues);
    return issues;
  }

  /// 按裁决规则修正整棵树，返回新树（不修改原对象）
  static OrbatNode apply(OrbatNode root) => _fix(root);

  /// 审计 + 修正一步到位，同时返回清单供 UI 展示
  static ({OrbatNode tree, List<AuditIssue> issues}) auditAndFix(OrbatNode root) {
    final issues = run(root);
    if (issues.isEmpty) return (tree: root, issues: issues);
    return (tree: _fix(root), issues: issues);
  }

  static void _walk(OrbatNode node, String path, List<AuditIssue> out) {
    final issue = _check(node, path);
    if (issue != null) out.add(issue);
    for (final c in node.children) {
      _walk(c, '$path/${c.uniqueDesignation}', out);
    }
  }

  static AuditIssue? _check(OrbatNode node, String path) {
    final code = Sidc.parse(node.sidc);
    if (code == null) return null; // 位数不对由校验器报红，这里不重复

    final guess = SidcRule.fromName(node.uniqueDesignation);
    final name = node.uniqueDesignation;

    // ---- ① 符号集：名称判定是空中，码却是陆地 ----
    final looksAir = RegExp(
            r'直升机|无人机|运输机|战斗机|攻击机|轰炸机|加油机|教练机|预警机|侦察机'
            r'|helicopter|drone|\buav\b|aircraft|fighter|bomber',
            caseSensitive: false)
        .hasMatch(name);
    final isArmyAviation = RegExp(r'航空兵|陆航|陆军航空|army aviation').hasMatch(name);
    if (looksAir && !isArmyAviation && code.symbolSet == '10') {
      final fixed = Sidc(
        symbolSet: '01',
        echelon: code.echelon,
        entity: _airEntityFor(name, code.entity),
        typeMod: code.typeMod,
        mobilityMod: code.mobilityMod,
        sectorMod: code.sectorMod,
      ).build();
      return AuditIssue(
        path: path,
        name: name,
        kind: AuditKind.symbolSet,
        modelSidc: node.sidc,
        suggestedSidc: fixed,
        reason: '「$name」是空中单位，符号集应为 01，模型给了 10（会渲染成方块）',
      );
    }

    // ---- ② 梯队：名称层级词 vs 模型梯队段 ----
    final guessEch = guess.echelon;
    // 只有"层级词在名称尾部"时才按名称改梯队：
    // 「2nd Division Postal Unit」开头有 Division 但那是母体名，改了反而错。
    if (guessEch != '00' &&
        code.echelon != '00' &&
        guessEch != code.echelon &&
        SidcRule.echelonAtTail(name)) {
      // 例外：本级指挥所（"第1营营部"）惯例低一级，guessEchelon 已按连级返回，
      // 若模型给的是"与父级相同"的码，那才是可疑的；这里统一按名称修正。
      final fixed = Sidc(
        symbolSet: code.symbolSet,
        echelon: guessEch,
        entity: code.entity,
        typeMod: code.typeMod,
        mobilityMod: code.mobilityMod,
        sectorMod: code.sectorMod,
      ).build();
      return AuditIssue(
        path: path,
        name: name,
        kind: AuditKind.echelon,
        modelSidc: node.sidc,
        suggestedSidc: fixed,
        reason: '「$name」层级词应为 $guessEch，模型给了 ${code.echelon}',
      );
    }

    // ---- ③ 兵种：本地能判定时才比对，判不出（000000）不硬改 ----
    if (guess.entity != '000000' && guess.entity != code.entity) {
      // 装甲/坦克这类模型常给 121102（装甲机械化）或 121105（步战车），本地给 120500，
      // 名称里明确有"坦克/装甲"时以本地为准。
      final strongName = RegExp(
              r'坦克|装甲|反坦克|迫击炮|火箭炮|防空|高炮|工兵|通信|医疗|侦察|后勤|保障'
              r'|tank|armou?red|anti-?tank|mortar|rocket|air ?defen[cs]e|engineer|signal|medical|recon')
          .hasMatch(name);
      if (strongName) {
        final fixed = Sidc(
          symbolSet: code.symbolSet,
          echelon: code.echelon,
          entity: guess.entity,
          typeMod: guess.typeMod,
          mobilityMod: guess.mobility,
          sectorMod: code.sectorMod,
        ).build();
        return AuditIssue(
          path: path,
          name: name,
          kind: AuditKind.arm,
          modelSidc: node.sidc,
          suggestedSidc: fixed,
          reason: '「$name」按名称应为 ${guess.entity}（${guess.reason}），'
              '模型给了 ${code.entity}',
        );
      }
    }

    return null;
  }

  /// 符号集从陆地切到空中时，主实体码语义完全不同，必须换一组码
  static String _airEntityFor(String name, String fallback) {
    final s = name.toLowerCase();
    if (RegExp(r'直升机|helicopter').hasMatch(s)) return '110200';
    if (RegExp(r'无人机|\buav\b|drone').hasMatch(s)) return '110300';
    if (RegExp(r'运输机|transport aircraft').hasMatch(s)) return '110107';
    if (RegExp(r'战斗机|fighter').hasMatch(s)) return '110104';
    if (RegExp(r'攻击机|attack').hasMatch(s)) return '110102';
    if (RegExp(r'轰炸机|bomber').hasMatch(s)) return '110105';
    if (RegExp(r'侦察机|recon').hasMatch(s)) return '110111';
    if (RegExp(r'加油机|tanker').hasMatch(s)) return '110109';
    if (RegExp(r'教练机|trainer').hasMatch(s)) return '110112';
    // 空中符号集下，原陆地实体码一定非法，退回通用固定翼
    return '110100';
  }

  static OrbatNode _fix(OrbatNode node) {
    final issue = _check(node, '');
    final sidc = issue?.suggestedSidc ?? node.sidc;
    return OrbatNode(
      uniqueDesignation: node.uniqueDesignation,
      additionalInformation: node.additionalInformation,
      sidc: sidc,
      children: node.children.map(_fix).toList(),
    );
  }
}
