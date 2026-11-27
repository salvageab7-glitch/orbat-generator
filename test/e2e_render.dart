/// 端到端测试：真实编制 JSON → 核心引擎校验 → 归一化 → 调用渲染器出图
///
/// 用法：dart run test/e2e_render.dart <input.json> [outBase]
/// 需要 node ≥ 24 + ._tools/render_orbat.js + 联网。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/core/orbat.dart';
import '../lib/render/renderer.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run test/e2e_render.dart <input.json> [outBase] [renderScript]',
    );
    exitCode = 64;
    return;
  }

  final srcPath = args[0];
  final outBase =
      args.length > 1 ? args[1] : '${Directory.current.path}/test/_e2e_auto';
  final script = args.length > 2
      ? args[2]
      : '${Directory.current.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}render_orbat.js';

  final src = File(srcPath);
  if (!src.existsSync()) {
    stderr.writeln('输入文件不存在: $srcPath');
    exitCode = 66;
    return;
  }

  // 1) 解析
  final raw = jsonDecode(await src.readAsString()) as Map<String, dynamic>;
  final root = OrbatNode.fromJson(raw);
  print('[1/4] 解析完成：${root.count} 个节点，最大层级 ${root.maxDepth}');

  // 2) 校验
  final report = OrbatValidator.validate(root);
  print('[2/4] 校验：红牌 ${report.redCount}，软警告 ${report.warnCount}');
  for (final i in report.issues.take(6)) {
    print('       $i');
  }
  if (!report.ok) {
    stderr.writeln('存在红牌错误，已中止出图。');
    exitCode = 1;
    return;
  }

  // 3) 归一化
  final normalized = normalizeTree(root, commandLevels: '2');
  final jsonStr = const JsonEncoder.withIndent('  ').convert(normalized);
  print('[3/4] 归一化完成：${jsonStr.length} 字符');

  // 4) 出图
  final renderer = OrbatRenderer(RendererConfig(scriptPath: script));
  print('[4/4] 出图中（联网，约 30-90 秒）...');
  final result = await renderer.render(
    normalizedJson: jsonStr,
    outputBase: outBase,
  );

  if (!result.ok) {
    stderr.writeln('出图失败：${result.error}');
    exitCode = 1;
    return;
  }

  final png = File(result.pngPath!);
  print('');
  print('=== 端到端通过 ===');
  print(
      '  PNG : ${result.pngPath} (${(png.lengthSync() / 1024).toStringAsFixed(0)} KB)');
  print('  SVG : ${result.svgPath ?? "未产出"}');
  print('  耗时: ${result.elapsed.inSeconds} 秒');
}
