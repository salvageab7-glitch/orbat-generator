/// 真实 DeepSeek 调用测试：图片 → ORBAT JSON
///
/// 用法：DEEPSEEK_API_KEY=sk-xxx dart run test/live_api.dart <image.png> [out.json]
/// 真实调用会产生费用（一次约几分钱），但这是验证识别质量的唯一方式。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/deepseek_client.dart';
import '../lib/ai/prompt.dart';
import '../lib/core/orbat.dart';
import '../lib/core/sidc.dart';

void main(List<String> args) async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('缺少环境变量 DEEPSEEK_API_KEY');
    exitCode = 64;
    return;
  }
  if (args.isEmpty) {
    stderr.writeln('用法: dart run test/live_api.dart <image.png> [out.json]');
    exitCode = 64;
    return;
  }

  final imgFile = File(args[0]);
  if (!imgFile.existsSync()) {
    stderr.writeln('图片不存在: ${args[0]}');
    exitCode = 66;
    return;
  }

  final bytes = await imgFile.readAsBytes();
  print('图片: ${args[0]} (${(bytes.length / 1024).toStringAsFixed(0)} KB)');

  final client = DeepSeekClient(
    config: DeepSeekConfig(
      apiKey: key,
      model: 'deepseek-flash',
      maxTokens: 16000,
      maxRetries: 1,
      timeout: const Duration(seconds: 180),
    ),
    systemPrompt: kOrbatSystemPrompt,
  );

  final sw = Stopwatch()..start();
  final result = await client.generateFromImage(
    imageBytes: bytes,
    mimeType: 'image/png',
    onProgress: (p) => print('  · $p'),
  );
  sw.stop();
  client.close();

  if (!result.ok) {
    stderr.writeln('失败（${result.attempts} 次尝试，${sw.elapsed.inSeconds}s）：${result.error}');
    if (result.rawJson.isNotEmpty) {
      stderr.writeln('原始返回前 500 字：\n${result.rawJson.substring(0, result.rawJson.length.clamp(0, 500))}');
    }
    exitCode = 1;
    return;
  }

  final tree = result.tree!;
  print('\n=== 生成成功 ===');
  print('耗时: ${sw.elapsed.inSeconds}s，尝试 ${result.attempts} 次');
  print('节点: ${tree.count}，层级: ${tree.maxDepth}');

  // 校验
  final report = OrbatValidator.validate(tree);
  print('校验: 红牌 ${report.redCount}，软警告 ${report.warnCount}');
  for (final i in report.issues.take(10)) {
    print('  $i');
  }

  // 打印树（最多 3 层）
  print('\n=== 结构 ===');
  void dump(OrbatNode n, int d) {
    if (d > 2) return;
    final s = Sidc.parse(n.sidc);
    final desc = s == null ? '非法码' : s.describe();
    print('${'  ' * d}${n.uniqueDesignation}  [$desc]');
    for (final c in n.children) {
      dump(c, d + 1);
    }
  }

  dump(tree, 0);

  // 保存
  final outPath = args.length > 1 ? args[1] : '${Directory.current.path}/test/_live_out.json';
  final normalized = normalizeTree(tree, commandLevels: '2');
  await File(outPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(normalized));
  print('\n已保存: $outPath');
}
