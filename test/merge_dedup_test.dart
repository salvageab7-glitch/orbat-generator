// 0.3.1 回归测试：分块识图合并去重
// 场景复刻 2026-11-18 澳军第 2 师图的实际缺陷：
//   4 块识图产出 3 个同级师根 + 1 个重复旅（残缺版/完整版分属不同父）
import 'package:flutter_test/flutter_test.dart';
import 'package:orbat_core/pipeline.dart';
import 'package:orbat_core/core/orbat.dart';
import 'package:orbat_core/core/auto_fix.dart';
import 'package:orbat_core/ai/image_prep.dart';
import 'dart:typed_data';

OrbatNode _n(String name,
    {String note = '', String? sidc, List<OrbatNode> children = const []}) {
  return OrbatNode(
    uniqueDesignation: name,
    additionalInformation: note,
    sidc: sidc ?? '130310002111000000000000000000',
    children: List.of(children),
  );
}

ImageTile _tile(int col) => ImageTile(
    png: Uint8List(0),
    row: 0,
    col: col,
    totalRows: 1,
    totalCols: 3,
    srcX: 0,
    srcY: 0,
    srcW: 0,
    srcH: 0);

String _dump(OrbatNode n, [int d = 0]) {
  final b = StringBuffer('${'  ' * d}- ${n.uniqueDesignation}'
      '${n.additionalInformation.isEmpty ? "" : " | ${n.additionalInformation}"}\n');
  for (final c in n.children) {
    b.write(_dump(c, d + 1));
  }
  return b.toString();
}

void main() {
  test('英文图：三根并列 + 残缺旅 → 单根 + 同名合并 + 占位清理', () {
    // 块1：残缺版（含 Sy[?] 占位、自检文本泄漏进注释）
    final block1 = _n('The Citizen Division 2nd …', children: [
      _n('5th Infantry Brigade', children: [
        _n('5th Bde HQ', note: 'Marrickville'),
        _n('3rd Infantry Battalion', note: 'The Werriwa Regiment Canberra'),
      ]),
      _n('8th Infantry Brigade', note: '名称被裁切', children: [
        _n('8th Bde HQ', note: 'M[?]'),
        _n('17th Infantry Battalion', note: 'Th[?]'),
        _n('Sy[?]', note: '支援单位，符号不清'),
      ]),
    ]);
    // 块2：师部视图（含完整版第8旅）
    final block2 = _n('2nd Division HQ', children: [
      _n('2nd Division Signals Regiment', note: 'Moore Park'),
      _n('8th Infantry Brigade', children: [
        _n('8th Bde HQ', note: '旅部 · Millers Point'),
        _n('17th/18th Infantry Battalion', note: 'Chatswood'),
        _n('Sydney University Regiment', note: 'Darlington'),
      ]),
    ]);
    // 块3：完整版主根
    final block3 = _n('2nd Division', children: [
      _n('2nd Division RAA', note: '皇家炮兵'),
    ]);

    final tiles = [
      (tree: block1, tile: _tile(0)),
      (tree: block2, tile: _tile(1)),
      (tree: block3, tile: _tile(2)),
    ];
    final merged = mergeTileTrees(tiles);
    final fixed = OrbatAutoFix.apply(merged);
    final dump = _dump(fixed);

    // ① 块根全部被吸收：不再有并列的杂名师根
    expect(dump.contains('The Citizen Division'), isFalse,
        reason: '杂名块根应被吸收，实际树:\n$dump');
    expect(dump.contains('2nd Division HQ'), isFalse,
        reason: '块根「2nd Division HQ」应被吸收，实际树:\n$dump');
    expect(fixed.uniqueDesignation, '2nd Division');

    // ② 第8旅只出现一次
    expect('8th Infantry Brigade'.allMatches(dump).length, 1,
        reason: '第8旅应去重为一份，实际树:\n$dump');

    // ③ 无残缺占位名残留（Sy[?] 被前缀匹配吸收）
    expect(dump.contains('[?]'), isFalse,
        reason: 'Sy[?] 等占位节点应被合并，实际树:\n$dump');

    // ④ 自检说明不再出现在注释字段
    expect(dump.contains('名称被裁切'), isFalse);
    expect(dump.contains('符号不清'), isFalse);

    // ⑤ 完整版注释保留
    expect(dump.contains('Millers Point'), isTrue);
    expect(dump.contains('Marrickville'), isTrue);
  });

  test('中文图回归：总根选择与同根吸收不受影响', () {
    final block1 = _n('第1海军陆战营', children: [
      _n('第1连'),
      _n('第2连'),
    ]);
    final block2 = _n('苏联海军步兵旅', children: [
      _n('第2海军陆战营'),
    ]);
    final tiles = [
      (tree: block1, tile: _tile(0)),
      (tree: block2, tile: _tile(1)),
    ];
    final merged = mergeTileTrees(tiles);
    expect(merged.uniqueDesignation, '苏联海军步兵旅');
  });
}
