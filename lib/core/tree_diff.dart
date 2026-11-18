/// 两份编制树的节点级差异
///
/// 用途：改了提示词/规则后重新生成，直观看出"多了什么、少了什么、改了什么"，
/// 而不是肉眼逐行比对 JSON。
library;

import 'orbat.dart';

enum DiffKind { added, removed, renamed, sidcChanged, noteChanged, moved }

class TreeDiffItem {
  final DiffKind kind;
  final String path;
  final String name;
  final String? oldValue;
  final String? newValue;

  const TreeDiffItem({
    required this.kind,
    required this.path,
    required this.name,
    this.oldValue,
    this.newValue,
  });

  String get label => switch (kind) {
        DiffKind.added => '新增',
        DiffKind.removed => '删除',
        DiffKind.renamed => '改名',
        DiffKind.sidcChanged => 'SIDC 变化',
        DiffKind.noteChanged => '注释变化',
        DiffKind.moved => '层级变化',
      };
}

class TreeDiff {
  final List<TreeDiffItem> items;

  const TreeDiff(this.items);

  bool get isEmpty => items.isEmpty;
  int countOf(DiffKind k) => items.where((i) => i.kind == k).length;
}

class TreeDiffer {
  /// 对比两棵树。oldTree 为 null 时表示全是新增。
  static TreeDiff compare(OrbatNode? oldTree, OrbatNode newTree) {
    final items = <TreeDiffItem>[];
    final oldMap = <String, OrbatNode>{};
    final newMap = <String, OrbatNode>{};

    void index(OrbatNode n, String path, Map<String, OrbatNode> out) {
      out[path] = n;
      for (var i = 0; i < n.children.length; i++) {
        index(n.children[i], '$path/${n.children[i].uniqueDesignation}#$i', out);
      }
    }

    if (oldTree != null) index(oldTree, '根', oldMap);
    index(newTree, '根', newMap);

    // 新增
    for (final e in newMap.entries) {
      if (!oldMap.containsKey(e.key)) {
        items.add(TreeDiffItem(
          kind: DiffKind.added,
          path: e.key,
          name: e.value.uniqueDesignation,
        ));
      }
    }

    // 删除
    for (final e in oldMap.entries) {
      if (!newMap.containsKey(e.key)) {
        items.add(TreeDiffItem(
          kind: DiffKind.removed,
          path: e.key,
          name: e.value.uniqueDesignation,
        ));
      }
    }

    // 修改：按名称匹配（跨路径），因为节点移动会导致 path 变
    final oldByName = <String, List<OrbatNode>>{};
    for (final n in oldMap.values) {
      oldByName.putIfAbsent(n.uniqueDesignation, () => []).add(n);
    }

    for (final e in newMap.entries) {
      final oldNode = oldMap[e.key];
      if (oldNode != null) {
        // 同路径：逐字段比
        if (oldNode.uniqueDesignation != e.value.uniqueDesignation) {
          items.add(TreeDiffItem(
            kind: DiffKind.renamed,
            path: e.key,
            name: e.value.uniqueDesignation,
            oldValue: oldNode.uniqueDesignation,
            newValue: e.value.uniqueDesignation,
          ));
        }
        if (oldNode.sidc != e.value.sidc) {
          items.add(TreeDiffItem(
            kind: DiffKind.sidcChanged,
            path: e.key,
            name: e.value.uniqueDesignation,
            oldValue: oldNode.sidc,
            newValue: e.value.sidc,
          ));
        }
        if (oldNode.additionalInformation != e.value.additionalInformation) {
          items.add(TreeDiffItem(
            kind: DiffKind.noteChanged,
            path: e.key,
            name: e.value.uniqueDesignation,
            oldValue: oldNode.additionalInformation,
            newValue: e.value.additionalInformation,
          ));
        }
      } else {
        // 路径不同但同名：视为层级变化
        final candidates = oldByName[e.value.uniqueDesignation];
        if (candidates != null && candidates.isNotEmpty) {
          final oldPath = oldMap.entries
              .where((x) => identical(x.value, candidates.first))
              .map((x) => x.key)
              .firstOrNull;
          if (oldPath != null) {
            items.add(TreeDiffItem(
              kind: DiffKind.moved,
              path: e.key,
              name: e.value.uniqueDesignation,
              oldValue: oldPath,
              newValue: e.key,
            ));
          }
        }
      }
    }

    return TreeDiff(items);
  }
}
