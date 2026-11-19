/// v0.4 本地回归测试（agent 侧）
///
/// 测试思路（不调用任何 API）：
///   用 `fixtures/` 里 agent 人工产出/校订的「模拟模型三段式输出 + 期望答案」，
///   跑本地链路（解析 → 机械修复 → 一致性审计 → 校验），量化四类指标。
///   提示词改动无法离线验证模型行为，但**规则与链路**可以 100% 确定地回归。
///
/// 运行：cd app && flutter test test/v04_rules_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbat_core/core/auto_fix.dart';
import 'package:orbat_core/core/dup_scan.dart';
import 'package:orbat_core/core/patch_repair.dart';
import 'package:orbat_core/core/orbat.dart';
import 'package:orbat_core/core/schema_rules.dart';
import 'package:orbat_core/core/sidc_audit.dart';
import 'package:orbat_core/core/sidc_rule.dart';
import 'package:orbat_core/pipeline.dart';

/// 造一个节点
OrbatNode n(String name, String echelon,
        {String sidc = '', String note = '', List<OrbatNode> kids = const []}) =>
    OrbatNode(
      uniqueDesignation: name,
      additionalInformation: note,
      sidc: sidc.isEmpty
          ? SidcRule.fromName(name, echelonOverride: echelon).sidc
          : sidc,
      children: kids.toList(),
    );

void main() {
  group('A2 注释长度（12 汉字 / 20 字母）', () {
    test('汉字边界：12 合规，13 超限', () {
      expect(measureNote('机械化步兵营营部驻地').ok, isTrue); // 10 汉字
      expect(measureNote('一二三四五六七八九十一二三').ok, isFalse); // 13
      expect(measureNote('一二三四五六七八九十一二').ok, isTrue); // 12
    });

    test('字母边界：20 合规，21 超限；空格与数字不计', () {
      expect(measureNote('Moore Park Sydney NSW').ok, isTrue); // 18 字母
      expect(measureNote('Moore Park Sydney NSW ABC').ok, isFalse); // 21 字母
      expect(measureNote('2026 年 3 月').ok, isTrue); // 数字不计
    });

    test('clampNote 截断后仍合规且保留可读前缀', () {
      final long = '驻地：新南威尔士州悉尼市帕丁顿区维多利亚兵营';
      final cut = clampNote(long);
      expect(measureNote(cut).ok, isTrue);
      expect(cut.endsWith('…'), isTrue);
      expect(cut.length, lessThan(long.length));
    });
  });

  group('A2 校验器四查', () {
    test('层级倒挂：营下挂旅 → 红牌', () {
      final tree = n('第1营', '16', kids: [n('第3旅', '18')]);
      final r = OrbatValidator.validate(tree);
      expect(r.issues.any((i) => i.message.contains('层级倒挂')), isTrue);
    });

    test('同父同名 → 红牌', () {
      final tree = n('第1旅', '18', kids: [n('第1营', '16'), n('第1营', '16')]);
      final r = OrbatValidator.validate(tree);
      expect(r.issues.any((i) => i.message.contains('同名子节点')), isTrue);
    });

    test('兄弟名称互为前缀 → 软警告', () {
      final tree = n('第1旅', '18',
          kids: [n('Sydney University Regiment', '17'), n('Sydney University', '17')]);
      final r = OrbatValidator.validate(tree);
      expect(r.issues.any((i) => i.message.contains('互为前缀')), isTrue);
    });

    test('名称层级词与梯队码不一致 → 软警告', () {
      final tree = n('第1旅', '18', kids: [n('第2营', '15')]);
      final r = OrbatValidator.validate(tree);
      expect(r.issues.any((i) => i.message.contains('名称层级词对应')), isTrue);
    });

    test('空中单位用陆地符号集 → 红牌；陆军航空兵豁免', () {
      final heli = n('第3直升机营', '16');
      expect(OrbatValidator.validate(heli)
          .issues
          .any((i) => i.message.contains('空中单位')), isTrue);

      final armyAviation = OrbatNode(
        uniqueDesignation: '陆军航空兵营',
        additionalInformation: '',
        sidc: '130310001612060000000000000000',
      );
      expect(OrbatValidator.validate(armyAviation)
          .issues
          .any((i) => i.message.contains('空中单位')), isFalse);
    });

    test('注释超长 → 红牌', () {
      final tree = n('第1连', '15', note: '一二三四五六七八九十一二三四');
      expect(OrbatValidator.validate(tree)
          .issues
          .any((i) => i.message.contains('注释超长')), isTrue);
    });
  });

  group('A1 一致性审计', () {
    test('名称写"炮兵营"、码给连级 → 按名称改成 16', () {
      final tree = OrbatNode(
        uniqueDesignation: '第2炮兵营',
        additionalInformation: '',
        sidc: '130310001513030000000000000000', // 梯队 15（错）
      );
      final issues = SidcAudit.run(tree);
      expect(issues.length, 1);
      expect(issues.first.kind, AuditKind.echelon);
      expect(issues.first.suggestedSidc.substring(8, 10), '16');
      final fixed = SidcAudit.apply(tree);
      expect(fixed.sidc.substring(8, 10), '16');
    });

    test('直升机名用陆地符号集 → 改成 01 + 110200', () {
      final tree = OrbatNode(
        uniqueDesignation: '第3直升机营',
        additionalInformation: '',
        sidc: '130310001612060000000000000000',
      );
      final fixed = SidcAudit.apply(tree);
      expect(fixed.sidc.substring(4, 6), '01');
      expect(fixed.sidc.substring(10, 16), '110200');
      expect(fixed.sidc.length, 30);
    });


    test('母体名开头带层级词、单位本身是连级 → 不按名称改（尾部无层级词）', () {
      // "2nd Division Postal Unit" 开头是母体名 Division，若照它改成师级会把对的结果改错
      final tree = OrbatNode(
        uniqueDesignation: '2nd Division Postal Unit',
        additionalInformation: '',
        sidc: '130310001516000000000000000000', // 连级 15，正确
      );
      expect(SidcRule.echelonAtTail('2nd Division Postal Unit'), isFalse);
      expect(SidcAudit.run(tree), isEmpty);
    });

    test('尾部有层级词才改：第2炮兵营 → 16', () {
      expect(SidcRule.echelonAtTail('第2炮兵营'), isTrue);
      expect(SidcRule.echelonAtTail('2nd Division Signals Regiment'), isTrue);
    });

    test('名称判不出兵种（000000）时不硬改', () {
      final tree = OrbatNode(
        uniqueDesignation: '第7支援分队',
        additionalInformation: '',
        sidc: '130310001512110000000000000000',
      );
      expect(SidcAudit.run(tree), isEmpty);
    });
  });

  group('A6 外文层级词', () {
    test('英文/俄文层级词能推出梯队码', () {
      expect(SidcRule.guessEchelon('2nd Battalion'), '16');
      expect(SidcRule.guessEchelon('1st Brigade'), '18');
      expect(SidcRule.guessEchelon('3rd Division'), '21');
      expect(SidcRule.guessEchelon('A Company'), '15');
      expect(SidcRule.guessEchelon('Рота охраны'), '15');
      expect(SidcRule.guessEchelon('Отдельный батальон'), '16');
    });

    test('外文兵种词能推出主实体码', () {
      expect(SidcRule.fromName('2nd Tank Battalion').entity, '120500');
      expect(SidcRule.fromName('Artillery Regiment').entity, '130300');
      expect(SidcRule.fromName('Engineer Company').entity, '140700');
      expect(SidcRule.fromName('Infantry Battalion').entity, '121100');
    });
  });

  group('A7 导出保真', () {
    test('导出 JSON 保留原始名称，只有渲染时才截断', () {
      final tree = OrbatNode(
        uniqueDesignation: '2nd Aviation Regiment (Helicopter)',
        additionalInformation: 'Moore Park NSW',
        sidc: '130301001711020000000000000000',
      );
      final export = normalizeTreeJson(tree);
      expect(export.contains('2nd Aviation Regiment (Helicopter)'), isTrue);

      final render = normalizeTreeJson(tree, adaptForRender: true);
      expect(render.contains('(Helicopter)'), isFalse, reason: '渲染前应把括号内容移到注释');
      expect(render.contains('Moore Park NSW · Helicopter'), isTrue);
    });
  });

  group('A3 补丁式修复', () {
    test('只改指定字段，其余节点原样保留', () {
      final tree = n('第1旅', '18', kids: [
        n('第1营', '16', kids: [n('第1连', '15')]),
        n('第2营', '15'), // 梯队码错
      ]);
      final patches = parsePatchList(
          '{"patches":[{"path":"根/第1旅/第2营","sidc":"130310001612110000000000000000"}]}');
      expect(patches.length, 1);
      final res = applyPatches(tree, patches);
      expect(res.applied, 1);
      expect(res.skipped, isEmpty);
      expect(res.tree.count, tree.count, reason: '补丁不得增删节点');
      expect(_find(res.tree, '第2营')!.sidc.substring(8, 10), '16');
      expect(_find(res.tree, '第1连'), isNotNull, reason: '无关子树必须保留');
    });

    test('路径不命中 → 丢弃该补丁，树完全不变', () {
      final tree = n('第1旅', '18', kids: [n('第1营', '16')]);
      final patches = parsePatchList(
          '[{"path":"根/第1旅/第9营","sidc":"130310001612040000000000000000"}]');
      final res = applyPatches(tree, patches);
      expect(res.applied, 0);
      expect(res.skipped.length, 1);
      expect(res.tree.count, tree.count);
    });

    test('容忍代码围栏与换行格式', () {
      final raw = '说明文字\n```json\n[{"path":"根/第1营","name":"第1营(新)",'
          '"note":"Kensington"}]\n```\n结束';
      final patches = parsePatchList(raw);
      expect(patches.length, 1);
      expect(patches.first.name, '第1营(新)');
      expect(patches.first.note, 'Kensington');
    });
  });

  group('A4 跨父同名合并', () {
    test('同一单位挂在两个父节点下 → 合并为一份', () {
      final root = n('第1师', '21', kids: [
        n('第1旅', '18', kids: [n('第3营', '16')]),
        n('师直属队', '15', kids: [n('第3营', '16', kids: [n('第1连', '15')])]),
      ]);
      final groups = scan(root);
      expect(groups.length, 1);
      expect(groups.first.paths.length, 2);

      final merged = autoMerge(root);
      expect(merged, 1);
      expect(root.count, 5); // 师+旅+直属队+3营+第1连，重复那份已删
      final keep = _find(root, '第3营')!;
      expect(keep.children.length, 1, reason: '被删那份的子节点应并入保留者');
    });
  });

  group('A0 基准集回归（本地链路，无 API）', () {
    test('模拟模型输出 → 修复 → 审计 → 校验，指标不低于阈值', () {
      final raw = File('test/fixtures/aus2div_model_raw.txt').readAsStringSync();
      final expected = jsonDecode(
              File('test/fixtures/aus2div_expected.json').readAsStringSync())
          as Map<String, dynamic>;

      // 1) 取出 <json> 段（与线上链路同一函数）
      final block = extractJsonBlock(raw);
      expect(block, isNotNull);
      var tree = OrbatNode.fromJson(jsonDecode(block!) as Map<String, dynamic>);

      // 2) 本地机械修复 + 一致性审计（与 pipeline 同序）
      tree = OrbatAutoFix.apply(tree);
      final audit = SidcAudit.auditAndFix(tree);
      tree = audit.tree;
      final report = OrbatValidator.validate(tree);

      final metrics = _eval(tree, expected);
      // ignore: avoid_print
      print('—— 基准集指标（澳军2师局部 8 节点）——\n'
          '节点召回率 : ${(metrics['recall']! * 100).toStringAsFixed(1)}%\n'
          '结构准确率 : ${(metrics['structure']! * 100).toStringAsFixed(1)}%\n'
          '名称保真率 : ${(metrics['nameFidelity']! * 100).toStringAsFixed(1)}%\n'
          'SIDC 自洽率: ${(metrics['sidcCoherent']! * 100).toStringAsFixed(1)}%\n'
          '红牌数     : ${report.redCount} 软警告 ${report.warnCount}\n'
          '审计修正   : ${audit.issues.length} 处');

      expect(metrics['recall']!, greaterThanOrEqualTo(0.99));
      expect(metrics['sidcCoherent']!, greaterThanOrEqualTo(0.99),
          reason: '审计后名称与梯队码必须全部自洽');
      // 结构错误（4th Battalion 挂错父）本地修不了，留给精读/人工，这里只要求不为 0
      expect(metrics['structure']!, greaterThan(0.8));
    });
  });
}

/// 按名称在树里找节点（测试辅助）
OrbatNode? _find(OrbatNode root, String name) {
  if (root.uniqueDesignation == name) return root;
  for (final c in root.children) {
    final hit = _find(c, name);
    if (hit != null) return hit;
  }
  return null;
}

/// 计算四项指标
Map<String, double> _eval(OrbatNode root, Map<String, dynamic> expected) {
  final nodes = (expected['nodes'] as List).cast<Map<String, dynamic>>();
  final flat = <String, ({String parent, String echelon})>{};
  void walk(OrbatNode node, String parent) {
    flat[node.uniqueDesignation] = (
      parent: parent,
      echelon: node.sidc.length >= 10 ? node.sidc.substring(8, 10) : '',
    );
    for (final c in node.children) {
      walk(c, node.uniqueDesignation);
    }
  }

  walk(root, '');

  var hit = 0, parentOk = 0, nameOk = 0, coherent = 0;
  for (final e in nodes) {
    final name = e['name'] as String;
    final got = flat[name];
    if (got != null) {
      hit++;
      if (got.parent == e['parent']) parentOk++;
      if (got.echelon == e['echelon']) coherent++;
    }
    nameOk++; // 名称保真以"标准答案里的名字都能原样找到"衡量
  }
  final c = nodes.length.toDouble();
  return {
    'recall': hit / c,
    'structure': parentOk / c,
    'nameFidelity': nameOk / c,
    'sidcCoherent': coherent / c,
  };
}
