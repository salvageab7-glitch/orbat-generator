/// 端到端桥接：读编制 JSON → 校验 → 归一化 → 输出标准化 JSON 供渲染器使用
/// 用法：dart run test/pipeline.dart <input.json> <output.json>
import 'dart:convert';
import 'dart:io';
import 'package:orbat_core/core/orbat.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run test/pipeline.dart <input.json> <output.json>');
    exitCode = 2;
    return;
  }
  final input = File(args[0]);
  if (!input.existsSync()) {
    stderr.writeln('找不到输入: ${args[0]}');
    exitCode = 2;
    return;
  }

  final decoded = json.decode(input.readAsStringSync()) as Map<String, dynamic>;
  final tree = OrbatNode.fromJson(decoded);
  final report = OrbatValidator.validate(tree);
  stdout.writeln(report.toString());

  if (!report.ok) {
    stderr.writeln('存在红牌，拒绝输出。请先修复。');
    exitCode = 1;
    return;
  }

  // commandLevels：节点>60 且高度大时用 2，这里简单按节点数给建议
  final levels = tree.count > 60 ? '2' : '1';
  final normalized = normalizeTree(tree, commandLevels: levels);
  File(args[1]).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(normalized),
    encoding: utf8,
  );
  stdout.writeln('已归一化输出: ${args[1]}（commandLevels=$levels）');
}
