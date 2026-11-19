/// 跨父节点全局同名扫描（v0.4 / A4）
///
/// 问题：分块识图时同一单位常被两块识别，分别挂到了**不同父节点**下
/// （旅部在 A 块挂到师下、B 块挂到旅下）。合并阶段只做"同父同名"去重，
/// 这种跨父重复会漏掉，产图上就出现两份同一个单位——用户一眼就能看出错。
///
/// 本模块做两件事：
///   1. `scan()`      —— 列出全局同名/近名节点组（供问题清单，人工判断）
///   2. `autoMerge()` —— 只对**名称完全一致**的组自动合并（保守策略）：
///        保留子树更完整的一份，把另一份的子节点并进去，删掉多余节点。
///        名称相近但不完全一致的组一律只报告，不自动改（误合并比重复更糟）。
library;

import 'orbat.dart';

class DuplicateGroup {
  /// 归一化后的名称（用于比对）
  final String key;

  /// 展示用名称（取第一份原文）
  final String displayName;

  /// 各份所在的路径（根/第1旅/第2营）
  final List<String> paths;

  const DuplicateGroup({
    required this.key,
    required this.displayName,
    required this.paths,
  });

  bool get isExact => paths.length > 1;
}

/// 归一化名称：去空白、去 [？] 标记、统一全角括号，便于比对
String normalizeName(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'\[\?\]'), '');
  s = s.replaceAll('（', '(').replaceAll('）', ')');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  return s.toLowerCase();
}

/// 扫描全树，返回出现 2 次及以上的名称组
List<DuplicateGroup> scan(OrbatNode root) {
  final index = <String, List<({String path, String name})>>{};
  void walk(OrbatNode node, String path) {
    final key = normalizeName(node.uniqueDesignation);
    if (key.isNotEmpty) {
      index.putIfAbsent(key, () => []).add((path: path, name: node.uniqueDesignation));
    }
    for (final c in node.children) {
      walk(c, '$path/${c.uniqueDesignation}');
    }
  }

  walk(root, root.uniqueDesignation);

  return index.entries
      .where((e) => e.value.length > 1)
      .map((e) => DuplicateGroup(
            key: e.key,
            displayName: e.value.first.name,
            paths: e.value.map((v) => v.path).toList(),
          ))
      .toList();
}

/// 自动合并"名称完全一致"的重复节点，返回合并了几处。
///
/// 保留策略：子树节点数更多的一份胜出（信息更全）；相等时保留靠前的一份。
/// 被删除那份的子节点会并入胜出者（按名称去重）。
///
/// 注意：本函数**原地修改** root 的 children 列表（树是刚构建出来的，
/// 外部没有其它引用），调用方不需要接收返回值。
int autoMerge(OrbatNode root, {List<String>? log}) {
  final groups = scan(root);
  var merged = 0;

  for (final g in groups) {
    // 收集该名称的所有节点实例（跨父节点）
    final hits = <({OrbatNode parent, int index, OrbatNode node})>[];
    void walk(OrbatNode parent) {
      for (var i = 0; i < parent.children.length; i++) {
        final c = parent.children[i];
        if (normalizeName(c.uniqueDesignation) == g.key) {
          hits.add((parent: parent, index: i, node: c));
        }
        walk(c);
      }
    }

    walk(root);
    if (hits.length < 2) continue;

    // 选保留者：子孙最多；相同则取靠前的
    hits.sort((a, b) => _descendants(b.node).compareTo(_descendants(a.node)));
    final keeper = hits.first.node;

    // 从后往前删，避免索引错位
    for (var k = hits.length - 1; k >= 1; k--) {
      final h = hits[k];
      // 安全阀：如果待删节点是保留者的祖先，删了会把保留者一起带走
      if (_isAncestor(h.node, keeper)) continue;
      // 把被删节点的子节点并入保留者（同名子节点不重复并入）
      for (final child in h.node.children) {
        final exists = keeper.children.any(
            (c) => normalizeName(c.uniqueDesignation) == normalizeName(child.uniqueDesignation));
        if (!exists) keeper.children.add(child);
      }
      // 按"对象身份"重新定位索引：跨父节点 + 前面的删除都可能让旧索引失效
      final idx = h.parent.children.indexWhere((c) => identical(c, h.node));
      if (idx >= 0) {
        h.parent.children.removeAt(idx);
        merged++;
        log?.add('合并重复「${h.node.uniqueDesignation}」（原路径 ${g.paths.length > k ? g.paths[k] : "?"}）');
      }
    }
  }

  return merged;
}

bool _isAncestor(OrbatNode maybeAncestor, OrbatNode node) {
  for (final c in maybeAncestor.children) {
    if (identical(c, node) || _isAncestor(c, node)) return true;
  }
  return false;
}

int _descendants(OrbatNode n) => n.count;
