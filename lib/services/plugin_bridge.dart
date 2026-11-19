/// 插件交接模式（安卓端 Agent 外挂）——目录协议与处理流水线
///
/// 手机本机 Agent 把本 App 当外挂插件用的固定交接协议：
/// ```
/// /storage/emulated/0/Download/
/// ├── orbat_inbox/    ← Agent 把编制 JSON 放这里（App 读取后移入 done/）
/// ├── orbat_outbox/   ← App 写产物：同名.png/.svg + 同名_report.json
/// └── orbat_docs/     ← 「导出 Agent 提示词」把 SIDC 工作流规范写这里
/// ```
/// 处理流程：normalize → validate（报告）→ 出图（WebView 线上渲染）→ 写产物。
/// Agent 自修复循环：读报告红牌 → 改 JSON → 重新放 inbox。
library;

import 'dart:convert';
import 'dart:io';

import '../ai/prompt.dart';
import '../core/orbat.dart';
import '../pipeline.dart';
import '../render/renderer.dart';

class PluginBridge {
  /// 公共 Download 根（安卓标准路径，所有安卓设备一致）
  static const String downloadRoot =
      '/storage/emulated/0/Download';

  static String get inboxDir => '$downloadRoot/orbat_inbox';
  static String get outboxDir => '$downloadRoot/orbat_outbox';
  static String get docsDir => '$downloadRoot/orbat_docs';
  static String get doneDir => '$inboxDir/done';

  static Directory get inbox => Directory(inboxDir);
  static Directory get outbox => Directory(outboxDir);

  /// 扫描待处理 JSON（按文件名排序，处理顺序稳定）
  static List<File> scanInbox() {
    if (!inbox.existsSync()) return const [];
    return inbox
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  static void ensureDirs() {
    for (final d in [inbox, outbox, Directory(doneDir), Directory(docsDir)]) {
      if (!d.existsSync()) d.createSync(recursive: true);
    }
  }

  /// 处理单个 JSON：
  /// 1) 解析 + 7 键归一化 → 2) 校验报告 → 3) 出图（回调注入渲染器）
  /// 4) 产物与报告写 outbox → 5) 源文件移入 done/
  static Future<Map<String, dynamic>> processOne(
    File jsonFile,
    Future<RenderResult> Function(String normalizedJson, String outputBase)
        render,
  ) async {
    final base = jsonFile.path
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
    final report = <String, dynamic>{
      'file': base,
      'ok': false,
      'nodeCount': 0,
      'depth': 0,
      'red': <Map<String, dynamic>>[],
      'warn': <Map<String, dynamic>>[],
      'render': <String, dynamic>{'ok': false},
    };

    String raw;
    try {
      raw = await jsonFile.readAsString();
    } catch (e) {
      report['error'] = '读取失败：$e';
      await _writeReport(base, report);
      return report;
    }

    // 解析 + 归一化
    final tree = parseTreeJson(raw);
    if (tree == null) {
      report['error'] = 'JSON 解析失败：不是合法的编制树（缺 name/sidc/children 结构）';
      await _writeReport(base, report);
      return report;
    }
    final normalized = normalizeTreeJson(tree, adaptForRender: true);
    final parsed = parseTreeJson(normalized)!;
    final validation = OrbatValidator.validate(parsed);
    report['nodeCount'] = _countNodes(parsed);
    report['depth'] = _depth(parsed);
    report['red'] = validation.issues
        .where((i) => i.level == 'red')
        .map((i) => {'path': i.path, 'message': i.message})
        .toList();
    report['warn'] = validation.issues
        .where((i) => i.level == 'warn')
        .map((i) => {'path': i.path, 'message': i.message})
        .toList();
    report['ok'] = validation.ok;
    await File('$outboxDir/$base.normalized.json')
        .writeAsString(normalized, flush: true);

    // 出图（红牌也继续渲染——Agent 可以从图+报告综合判断）
    try {
      final result = await render(normalized, '$outboxDir/$base');
      report['render'] = {
        'ok': result.ok,
        'png': result.pngPath,
        'svg': result.svgPath,
        if (!result.ok) 'error': result.error,
      };
    } catch (e) {
      report['render'] = {'ok': false, 'error': '$e'};
    }

    await _writeReport(base, report);
    // 源文件移入 done/（避免重复处理）
    try {
      await jsonFile.rename('$doneDir/${jsonFile.path.split(Platform.pathSeparator).last}');
    } catch (_) {}
    return report;
  }

  static Future<void> _writeReport(
      String base, Map<String, dynamic> report) async {
    await File('$outboxDir/$base.report.json')
        .writeAsString(jsonEncode(report), flush: true);
  }

  /// 导出 Agent 工作流提示词到 orbat_docs/（对应 Windows 模式三 `prompts` 命令）
  static Future<String> exportPrompts() async {
    ensureDirs();
    final buf = StringBuffer()
      ..writeln('===== 文字/修复（完整 SIDC 规范）=====')
      ..writeln(kOrbatSystemPrompt)
      ..writeln()
      ..writeln('===== 识图工作流（分块读图，agent 三段式）=====')
      ..writeln(kTileSystemPrompt);
    final path = '$docsDir/agent_prompts.txt';
    await File(path).writeAsString(buf.toString(), flush: true);
    return path;
  }

  static int _countNodes(OrbatNode n) =>
      1 + n.children.fold(0, (s, c) => s + _countNodes(c));

  static int _depth(OrbatNode n, [int d = 1]) => n.children.isEmpty
      ? d
      : n.children.map((c) => _depth(c, d + 1)).reduce((a, b) => a > b ? a : b);
}
