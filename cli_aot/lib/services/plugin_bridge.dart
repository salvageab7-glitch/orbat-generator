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
import '../core/logger.dart';
import '../core/orbat.dart';
import '../pipeline.dart';
import '../render/renderer.dart';

class PluginBridge {
  /// 公共 Download 根（安卓标准路径，所有安卓设备一致）
  static const String downloadRoot = '/storage/emulated/0/Download';

  static String get inboxDir => '$downloadRoot/orbat_inbox';
  static String get outboxDir => '$downloadRoot/orbat_outbox';
  static String get docsDir => '$downloadRoot/orbat_docs';
  static String get doneDir => '$inboxDir/done';

  static Directory get inbox => Directory(inboxDir);
  static Directory get outbox => Directory(outboxDir);

  static const int maxInboxEntriesToInspect = 2000;
  static const int maxFilesPerBatch = 100;
  static const int maxJsonFileBytes = 10 * 1024 * 1024;

  /// 有界异步扫描 inbox，避免公共目录中的海量条目占满内存。
  /// 每批最多处理 100 个 JSON；剩余文件留待下一次触发。
  static Future<List<File>> scanInbox() async {
    if (!await inbox.exists()) return const [];
    final files = <File>[];
    var inspected = 0;
    await for (final entry in inbox.list(followLinks: false)) {
      if (++inspected > maxInboxEntriesToInspect) break;
      if (entry is File && entry.path.toLowerCase().endsWith('.json')) {
        files.add(entry);
        if (files.length >= maxFilesPerBatch) break;
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static void ensureDirs() {
    for (final d in [inbox, outbox, Directory(doneDir), Directory(docsDir)]) {
      if (!d.existsSync()) d.createSync(recursive: true);
    }
  }

  /// 处理单个 JSON：
  /// 1) 解析 + 7 键归一化 → 2) 校验报告 → 3) 出图（回调注入渲染器）
  /// 4) 产物与报告写 outbox → 5) 源文件移入 done/
  static String newRunId() {
    final DateTime d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}-'
        '${d.millisecond.toString().padLeft(3, '0')}'
        '${d.microsecond.toString().padLeft(3, '0').substring(0, 3)}';
  }

  static Future<Map<String, dynamic>> processOne(
    File jsonFile,
    Future<RenderResult> Function(String normalizedJson, String outputBase)
        render, {
    String? runId,
    String? commandLevelsOverride,
  }) async {
    final String effectiveRunId = runId ?? newRunId();
    final sourceName = jsonFile.path.split(Platform.pathSeparator).last;
    final rawBase = sourceName
        .replaceAll(RegExp(r'\.json$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    final base = rawBase.isEmpty ? 'input' : rawBase;
    // 固定目录 + runId 后缀：同名输入不再覆盖历史产物。
    final artifactBase = '${base}__$effectiveRunId';
    final report = <String, dynamic>{
      'file': base,
      'runId': effectiveRunId,
      'artifactBase': artifactBase,
      'deliverable': false,
      'ok': false,
      'nodeCount': 0,
      'depth': 0,
      'red': <Map<String, dynamic>>[],
      'warn': <Map<String, dynamic>>[],
      'render': <String, dynamic>{'ok': false},
    };

    String raw;
    try {
      final size = await jsonFile.length();
      if (size > maxJsonFileBytes) {
        report['error'] =
            'JSON 文件超过大小上限（${maxJsonFileBytes ~/ (1024 * 1024)} MiB）';
        await _writeReport(base, report);
        await _archiveSource(jsonFile);
        return report;
      }
      final bytes = <int>[];
      await for (final chunk in jsonFile.openRead(0, maxJsonFileBytes + 1)) {
        bytes.addAll(chunk);
      }
      if (bytes.length > maxJsonFileBytes) {
        report['error'] =
            'JSON 文件超过大小上限（${maxJsonFileBytes ~/ (1024 * 1024)} MiB）';
        await _writeReport(base, report);
        await _archiveSource(jsonFile);
        return report;
      }
      raw = utf8.decode(bytes);
    } catch (e) {
      report['error'] = '读取失败：$e';
      await _writeReport(base, report);
      await _archiveSource(jsonFile);
      return report;
    }

    // 解析 + 归一化
    final tree = parseTreeJson(raw);
    if (tree == null) {
      report['error'] = 'JSON 解析失败：不是合法或超出限制的编制树';
      await _writeReport(base, report);
      await _archiveSource(jsonFile);
      return report;
    }
    final String commandLevelsInput = tree.commandLevels.trim();
    final String? pref =
        (commandLevelsOverride == '2' || commandLevelsOverride == '3')
            ? commandLevelsOverride
            : null;
    final String commandLevelsOutput =
        pref ?? (commandLevelsInput == '2' ? '2' : '3');
    final normalized = normalizeTreeJson(
      tree,
      commandLevels: commandLevelsOutput,
      adaptForRender: true,
    );
    final parsed = parseTreeJson(normalized)!;
    final validation = OrbatValidator.validate(parsed);
    report['commandLevelsInput'] = commandLevelsInput;
    report['commandLevelsOutput'] = commandLevelsOutput;
    report['commandLevelsSource'] = pref != null ? 'settings' : 'json';
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
    await File('$outboxDir/$artifactBase.normalized.json')
        .writeAsString(normalized, flush: true);

    // 红牌阻断出图：与桌面/GUI/CLI 的契约一致，避免把错误编制图当成功产物。
    if (!validation.ok) {
      report['render'] = {
        'ok': false,
        'skipped': true,
        'reason': '存在红牌错误，已跳过出图',
      };
    } else {
      try {
        final result = await render(normalized, '$outboxDir/$artifactBase');
        final quality = result.quality;
        report['render'] = {
          'ok': result.ok,
          'png': result.pngPath,
          'svg': result.svgPath,
          'quality': quality?.toJson(),
          if (!result.ok) 'error': result.error,
        };
        report['deliverable'] = result.ok && (quality?.ok ?? false);
      } catch (e) {
        report['render'] = {'ok': false, 'error': '$e'};
        report['deliverable'] = false;
      }
    }

    await _writeReport(artifactBase, report);
    report['reportPath'] = '$outboxDir/$artifactBase.report.json';
    await _archiveSource(jsonFile);
    return report;
  }

  /// 将成功、无效或不可读的输入移出 inbox；同名文件不互相覆盖。
  static Future<void> _archiveSource(File source) async {
    try {
      final directory = Directory(doneDir);
      await directory.create(recursive: true);
      final name = source.path.split(Platform.pathSeparator).last;
      var destination = File('${directory.path}/$name');
      if (await destination.exists()) {
        final dot = name.lastIndexOf('.');
        final stem = dot > 0 ? name.substring(0, dot) : name;
        final extension = dot > 0 ? name.substring(dot) : '';
        destination = File(
          '${directory.path}/${stem}_${DateTime.now().microsecondsSinceEpoch}$extension',
        );
      }
      await source.rename(destination.path);
    } catch (_) {
      // 若归档失败，保留源文件以便 Agent 修复或下一次重试。
    }
  }

  static Future<void> _writeReport(
    String base,
    Map<String, dynamic> report,
  ) async {
    await File('$outboxDir/$base.report.json')
        .writeAsString(jsonEncode(report), flush: true);
  }

  /// 批处理状态信号文件（Agent 轮询 orbat_outbox/_status.json 判定完成）
  static Future<void> writeStatus(Map<String, dynamic> status) async {
    await File('$outboxDir/_status.json')
        .writeAsString(jsonEncode(status), flush: true);
  }

  /// 导出 Agent 工作流提示词到 orbat_docs/（对应 Windows 模式三 `prompts` 命令）
  static Future<String> exportPrompts() async {
    ensureDirs();
    final buf = StringBuffer()
      ..writeln('# PROMPT_VERSION: $kPromptContractVersion')
      ..writeln('# COMMENT_LIMIT: 12 CJK / 20 letters')
      ..writeln('# SIDC_BASE: 0-based')
      ..writeln('# GENERATED: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('===== 文字/修复（完整 SIDC 规范）=====')
      ..writeln(kOrbatSystemPrompt)
      ..writeln()
      ..writeln('===== 识图工作流（分块读图，agent 三段式）=====')
      ..writeln(kTileSystemPrompt);
    final path = '$docsDir/agent_prompts.txt';
    await File(path).writeAsString(buf.toString(), flush: true);
    return path;
  }

  /// 确保 orbat_docs/agent_prompts.txt 是当前契约版本；旧 24 字文件会被重写。
  static Future<String> ensurePromptsCurrent() async {
    ensureDirs();
    final path = '$docsDir/agent_prompts.txt';
    final file = File(path);
    try {
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.contains('# PROMPT_VERSION: $kPromptContractVersion')) {
          return path;
        }
      }
    } catch (_) {}
    return exportPrompts();
  }

  /// 把最近的应用日志尾部写到 outbox，供 Agent 读取失败原因。
  ///
  /// 返回 `(path, tail)`；日志不可用时返回 null。尾部限制 80 行/8000 字符。
  static Future<({String path, String tail})?> writeDiagnostics(
    String runId, {
    int maxLines = 80,
  }) async {
    try {
      // 优先用 logger 的内存尾部（含尚未落盘的行），避免刚失败时读到空日志。
      String tail = AppLogger.instance.readTail(maxLines: maxLines);
      if (tail.isEmpty) {
        final String? logPath = AppLogger.instance.currentLogPath;
        if (logPath == null || logPath.isEmpty) return null;
        final File logFile = File(logPath);
        if (!await logFile.exists()) return null;
        final String text = await logFile.readAsString();
        final List<String> lines = text.split('\n');
        final List<String> tailLines = lines.length <= maxLines
            ? lines
            : lines.sublist(lines.length - maxLines);
        tail = tailLines.join('\n').trim();
      }
      if (tail.length > 8000) tail = tail.substring(tail.length - 8000);
      final File out = File('$outboxDir/$runId.log.txt');
      await out.writeAsString(tail, flush: true);
      return (path: out.path, tail: tail);
    } catch (_) {
      return null;
    }
  }

  static int _countNodes(OrbatNode n) =>
      1 + n.children.fold(0, (s, c) => s + _countNodes(c));

  static int _depth(OrbatNode n, [int d = 1]) => n.children.isEmpty
      ? d
      : n.children.map((c) => _depth(c, d + 1)).reduce((a, b) => a > b ? a : b);
}
