import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbat_core/core/orbat.dart';
import 'package:orbat_core/pipeline.dart';

Map<String, dynamic> node({
  String name = '测试单位',
  String sidc = '100310000011000000000000000000',
  List<dynamic> children = const <dynamic>[],
}) => {
  'options': {
    'uniqueDesignation': name,
    'additionalInformation': '',
    'sidc': sidc,
  },
  'subOrganizations': children,
};

void main() {
  test('接受符合渲染器 schema 的根和叶节点', () {
    final parsed = parseTreeJson(jsonEncode(node()));
    expect(parsed, isNotNull);
    expect(parsed!.uniqueDesignation, '测试单位');
    expect(parsed.count, 1);
  });

  test('拒绝空对象、缺必填 options 和错误类型子节点', () {
    expect(parseTreeJson('{}'), isNull);
    expect(parseTreeJson(jsonEncode({'name': '旧别名', 'sidc': 'x'})), isNull);
    expect(parseTreeJson(jsonEncode(node(children: ['not a node']))), isNull);
    expect(
      () => OrbatNode.fromJson(<String, dynamic>{}),
      throwsFormatException,
    );
  });

  test('拒绝超过深度上限的递归输入', () {
    Map<String, dynamic> root = node();
    for (var i = 0; i < 128; i++) {
      root = node(name: '深层', children: [root]);
    }
    expect(parseTreeJson(jsonEncode(root)), isNull);
    expect(() => OrbatNode.fromJson(root), throwsFormatException);
  });

  test('超宽树在待处理队列增长时即被拒绝', () {
    final root = node(
      children: List.generate(50000, (i) => node(name: '单位$i')),
    );
    expect(() => OrbatNode.fromJson(root), throwsFormatException);
  });
}
