/// 补丁式修复 —— 用"改哪几个字段"替代"重写整棵树"
///
/// 为什么必须换掉整树重写（v0.4 / A3）：
///   `auto_fix.dart` 的注释里记着实测事故——176 个节点的编制交给模型"修一遍"，
///   它只返回 32 个节点。大 JSON 要么被截断，要么模型自己把结构压缩了。
///   只要修复被触发一次，就可能丢掉大半棵树。
///
/// 本模块的做法：
///   模型只返回 `[{"path":"根/第1旅/第2营","sidc":"...","note":"..."}]`，
///   程序按路径把这些字段应用到原树上。**任何情况下不替换整棵树**：
///   路径不存在就丢弃该条（并记录），绝不会因为模型输出退化而丢数据。
library;

import 'dart:convert';

import 'orbat.dart';

/// 一条字段补丁
class NodePatch {
  final String path;
  final String? name;
  final String? sidc;
  final String? note;

  const NodePatch({required this.path, this.name, this.sidc, this.note});

  bool get isEmpty => name == null && sidc == null && note == null;

  @override
  String toString() => 'Patch($path, name=$name, sidc=$sidc, note=$note)';
}

/// 应用结果
class PatchResult {
  final OrbatNode tree;

  /// 实际写进树里的字段条数
  final int applied;

  /// 因路径找不到而丢弃的补丁路径
  final List<String> skipped;

  const PatchResult(this.tree, this.applied, this.skipped);

  bool get ok => applied > 0;
}

/// 解析模型返回的补丁。容忍四种常见形态：
///   1. 纯数组 `[{...},{...}]`
///   2. 包一层 `{"patches":[...]}`
///   3. 外面套了 ```json 围栏
///   4. 前后夹带说明文字
///
/// 键名同时接受中英混写（sidc/SIDC、name/uniqueDesignation、note/additionalInformation），
/// 因为模型偶尔会自作主张换键名。
List<NodePatch> parsePatchList(String raw) {
  var s = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();

  dynamic decoded;
  decoded = _tryJson(s);
  if (decoded == null) {
    final lb = s.indexOf('[');
    final rb = s.lastIndexOf(']');
    if (lb >= 0 && rb > lb) decoded = _tryJson(s.substring(lb, rb + 1));
  }
  if (decoded == null) {
    final ob = s.indexOf('{');
    final oe = s.lastIndexOf('}');
    if (ob >= 0 && oe > ob) decoded = _tryJson(s.substring(ob, oe + 1));
  }
  if (decoded == null) return const [];

  List<dynamic> list;
  if (decoded is List) {
    list = decoded;
  } else if (decoded is Map && decoded['patches'] is List) {
    list = decoded['patches'] as List;
  } else if (decoded is Map) {
    list = [decoded];
  } else {
    return const [];
  }

  final out = <NodePatch>[];
  for (final item in list) {
    if (item is! Map) continue;
    final path = (item['path'] ?? item['路径'] ?? '').toString().trim();
    if (path.isEmpty) continue;

    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = item[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    final p = NodePatch(
      path: path,
      name: pick(['name', 'uniqueDesignation', '名称', '番号']),
      sidc: pick(['sidc', 'SIDC', 'code', '码']),
      note: pick(['note', 'additionalInformation', '注释']),
    );
    if (!p.isEmpty) out.add(p);
  }
  return out;
}

dynamic _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

/// 应用补丁，返回新树。路径按 uniqueDesignation 逐段匹配
/// （第 0 段可以是"根"/"root"或根名，会被自动去掉）。
PatchResult applyPatches(OrbatNode root, List<NodePatch> patches) {
  if (patches.isEmpty) return PatchResult(root, 0, const []);

  final rootPath = root.uniqueDesignation;
  final skipped = <String>[];
  var applied = 0;

  List<String> segsOf(String path) {
    final segs = path
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (segs.isNotEmpty && (segs.first == '根' || segs.first == 'root')) {
      segs.removeAt(0);
    }
    if (segs.isNotEmpty && segs.first == rootPath) segs.removeAt(0);
    return segs;
  }

  // 预筛：路径不存在直接记跳过，绝不"猜"节点
  final byPath = <String, List<NodePatch>>{};
  for (final p in patches) {
    final segs = segsOf(p.path);
    if (segs.isEmpty || !_pathExists(root, segs)) {
      skipped.add(p.path);
      continue;
    }
    byPath.putIfAbsent(segs.join('/'), () => <NodePatch>[]).add(p);
  }

  OrbatNode fix(OrbatNode node, String canonicalPath) {
    var name = node.uniqueDesignation;
    var sidc = node.sidc;
    var note = node.additionalInformation;

    final hits = byPath[canonicalPath];
    if (hits != null) {
      for (final p in hits) {
        if (p.name != null) name = p.name!;
        if (p.sidc != null) sidc = p.sidc!;
        if (p.note != null) note = p.note!;
        applied++;
      }
    }

    return OrbatNode(
      uniqueDesignation: name,
      additionalInformation: note,
      sidc: sidc,
      children: node.children
          .map((c) => fix(
              c,
              canonicalPath.isEmpty
                  ? c.uniqueDesignation
                  : '$canonicalPath/${c.uniqueDesignation}'))
          .toList(),
    );
  }

  return PatchResult(fix(root, ''), applied, skipped);
}

bool _pathExists(OrbatNode root, List<String> segs) {
  var cur = root;
  for (final seg in segs) {
    OrbatNode? next;
    for (final c in cur.children) {
      if (c.uniqueDesignation == seg) {
        next = c;
        break;
      }
    }
    if (next == null) return false;
    cur = next;
  }
  return true;
}
