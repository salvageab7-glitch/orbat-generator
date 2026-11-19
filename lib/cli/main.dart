/// ORBAT CLI —— 供外部 AI Agent 调用的命令行接口
///
/// 设计约束：
///   · stdout **只输出 JSON**，一行或一个 JSON 对象，机器可直接 json.loads
///   · 所有诊断/进度/日志走 stderr，绝不污染 stdout
///   · 输入优先读 stdin（管道），也接受文件参数
///   · 任何错误都返回结构化的 {"ok":false,"error":...} 且 exit code ≠ 0
///
/// 用法见 `orbat.bat --help`
library;

import 'dart:convert';
import 'dart:io';

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../core/auto_fix.dart';
import '../core/dup_scan.dart';
import '../core/orbat.dart';
import '../core/patch_repair.dart';
import '../core/sidc_audit.dart';
import '../core/self_check.dart';
import '../core/usage_store.dart';
import '../pipeline.dart';
import '../ai/image_prep.dart';
import '../ai/prompt.dart';
import '../services/settings_store.dart';

void _out(Map<String, dynamic> obj) {
  stdout.writeln(jsonEncode(obj));
}

void _err(String msg) {
  stderr.writeln('[orbat-cli] $msg');
}

Map<String, dynamic> _ok(String cmd, Map<String, dynamic> data) {
  // 产物目录宣告：AI Agent 调用 CLI 后，必须能明确知道产物落在哪个文件夹。
  // 从 data 里的路径字段提取父目录；取不到则用输出目录配置/桌面。
  String? dir;
  for (final k in ['png', 'svg', 'json', 'outJson', 'outputBase']) {
    final v = data[k];
    if (v is String && v.isNotEmpty) {
      dir = File(v).parent.path;
      break;
    }
  }
  final d = data['outputDir'] ?? dir ?? _defaultCliOutputDir();
  return {
    'ok': true,
    'command': cmd,
    'data': {
      ...data,
      // 明确宣告给 Agent：产物生成目标目录（绝对路径）
      'outputDir': d,
    },
  };
}

/// CLI 兜底输出目录（命令自身已优先用输入目录）。
///
/// 0.3.2 起统一为 exe 同级「输出文件存档\」：与 GUI 一致、不写桌面根，
/// 且对 Agent 调用方而言目录位置可预测（就在 orbat-cli.exe 旁边）。
String _defaultCliOutputDir() => ensureArchiveDir();

Map<String, dynamic> _fail(String cmd, String msg) => {
      'ok': false,
      'command': cmd,
      'error': msg,
    };

/// 读取输入：优先 stdin（有管道数据时），否则按路径读文件
Future<String?> _readInput(List<String> args) async {
  // 找到第一个非选项参数（注意：选项的值也是非选项参数，需排除）
  final positional = _positionalArgs(args);

  if (positional.isNotEmpty) {
    // 有文件参数 → 直接读文件，完全不碰 stdin（避免事件循环挂住）
    final f = File(positional.first);
    if (f.existsSync()) return f.readAsStringSync();
    return null;
  }

  // 没有文件参数 → 从 stdin 读全部（管道模式）。
  // 关键：加超时兜底。无参数且无管道时（用户/Agent 误用），await for 会永远
  // 等待终端输入导致挂死；有管道时数据会很快到达并在 EOF 后结束。
  // 主入口有 exit(exitCode) 强制退出，所以超时后即使订阅还在也不影响进程退出。
  try {
    final chunks = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList()
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => const <String>[],
        );
    if (chunks.isEmpty) return null;
    return chunks.join('\n');
  } catch (_) {
    return null;
  }
}

/// 提取位置参数（排除 --key value 里的 value）
List<String> _positionalArgs(List<String> args) {
  const valueOptions = {
    'in', 'out', 'image', 'text', 'extra', 'command-levels',
  };
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) {
      // 判断它是不是前一个 --key 的值
      if (i > 0 && args[i - 1].startsWith('--')) {
        final prevKey = args[i - 1].substring(2).split('=').first;
        if (valueOptions.contains(prevKey)) continue;
      }
      out.add(a);
    }
  }
  return out;
}

Future<void> _runMain(List<String> args) async {
  // 把工作目录固定到脚本所在目录的上级（app/），避免相对路径找错
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent;
    final appDir = scriptDir.parent;
    if (File('${appDir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      Directory.current = appDir.path;
    }
  } catch (_) {}

  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _err(_help);
    _out({'ok': true, 'command': 'help', 'data': {'usage': _help}});
    return;
  }

  final cmd = args.first;
  final rest = args.skip(1).toList();

  // 日志系统初始化（失败不影响 CLI）
  await AppLogger.instance.init();

  try {
    switch (cmd) {
      case 'parse':
        await _cmdParse(rest);
        break;
      case 'audit':
        await _cmdAudit(args);
        break;
      case 'edit':
        await _cmdEdit(args);
        break;
      case 'validate':
        await _cmdValidate(rest);
        break;
      case 'normalize':
        await _cmdNormalize(rest);
        break;
      case 'render':
        await _cmdRender(rest);
        break;
      case 'generate':
        await _cmdGenerate(rest);
        break;
      case 'selfcheck':
        await _cmdSelfCheck(rest);
        break;
      case 'usage':
        await _cmdUsage(rest);
        break;
      case 'config':
        await _cmdConfig(rest);
        break;
      case 'prompts':
        await _cmdPrompts(rest);
        break;
      case 'batch':
        await _cmdBatch(rest);
        break;
      case 'retry-tile':
        await _cmdRetryTile(rest);
        break;
      default:
        _out(_fail(cmd, '未知命令: $cmd。用 --help 查看可用命令。'));
        exitCode = 2;
    }
  } catch (e, st) {
    _err('异常: $e');
    _err(st.toString().split('\n').take(4).join('\n'));
    _out(_fail(cmd, '$e'));
    exitCode = 1;
  }
}

// ---------- 命令实现 ----------

Future<void> _cmdParse(List<String> args) async {
  final text = await _readInput(args);
  if (text == null) {
    _out(_fail('parse', '没有输入：请传文件路径或通过 stdin 管道输入 JSON'));
    exitCode = 2;
    return;
  }
  try {
    final tree = parseTreeJson(text);
    if (tree == null) throw const FormatException('JSON 无法解析为编制树');
    _out(_ok('parse', {
          'nodeCount': tree.count,
          'maxDepth': tree.maxDepth,
          'root': tree.uniqueDesignation,
        }));
  } catch (e) {
    _out(_fail('parse', '解析失败: $e'));
    exitCode = 1;
  }
}

Future<void> _cmdValidate(List<String> args) async {
  final text = await _readInput(args);
  if (text == null) {
    _out(_fail('validate', '没有输入：请传文件路径或通过 stdin 管道输入 JSON'));
    exitCode = 2;
    return;
  }
  try {
    final tree = parseTreeJson(text);
    if (tree == null) throw const FormatException('JSON 无法解析为编制树');
    final report = OrbatValidator.validate(tree);
    _out(_ok('validate', {
          'nodeCount': report.nodeCount,
          'depth': report.depth,
          'redCount': report.redCount,
          'warnCount': report.warnCount,
          'ok': report.ok,
          'issues': report.issues
              .map((i) => {
                    'level': i.level,
                    'path': i.path,
                    'message': i.message,
                  })
              .toList(),
        }));
    if (!report.ok) exitCode = 3; // 红牌
  } catch (e) {
    _out(_fail('validate', '$e'));
    exitCode = 1;
  }
}

/// audit/edit 用：优先 --in <文件>，其次位置参数/stdin
Future<String?> _readInputWithIn(List<String> args) async {
  final inPath = _option(args, 'in');
  if (inPath != null && inPath.isNotEmpty) {
    final f = File(inPath);
    if (!f.existsSync()) throw FormatException('输入文件不存在: $inPath');
    return await f.readAsString();
  }
  return _readInput(args);
}

/// audit —— 一致性审计 + 结构校验 + 跨父同名扫描（只读，不改文件）
Future<void> _cmdAudit(List<String> args) async {
  final text = await _readInputWithIn(args);
  if (text == null) {
    _out(_fail('audit', '没有输入：请传文件路径或通过 stdin 管道输入 JSON'));
    exitCode = 2;
    return;
  }
  try {
    final tree = parseTreeJson(text);
    if (tree == null) throw const FormatException('JSON 无法解析为编制树');
    final audit = SidcAudit.run(tree);
    final report = OrbatValidator.validate(tree);
    final dups = scan(tree);
    _out(_ok('audit', {
      'nodeCount': tree.count,
      'depth': tree.maxDepth,
      'sidcMismatchCount': audit.length,
      'sidcMismatches': audit
          .map((a) => {
                'path': a.path,
                'name': a.name,
                'kind': a.kind.name,
                'current': a.modelSidc,
                'suggested': a.suggestedSidc,
                'reason': a.reason,
              })
          .toList(),
      'duplicateCount': dups.length,
      'duplicates': dups
          .map((d) => {'name': d.displayName, 'paths': d.paths})
          .toList(),
      'redCount': report.redCount,
      'warnCount': report.warnCount,
      'issues': report.issues
          .map((i) => {'level': i.level, 'path': i.path, 'message': i.message})
          .toList(),
    }));
  } catch (e) {
    _out(_fail('audit', '$e'));
    exitCode = 1;
  }
}

/// edit —— 按路径改单位名称/注释/SIDC（补丁式，绝不重写整棵树）
///
/// 用法：
///   orbat-cli edit --in 编制.json --path "根/第1旅/第2营" --name "新名" --note "驻地" --out 新.json
///   orbat-cli edit --in 编制.json --patches 补丁.json --out 新.json
/// 省略 --out 时直接覆盖输入文件（有 --in/文件参数才行）。
Future<void> _cmdEdit(List<String> args) async {
  final text = await _readInputWithIn(args);
  if (text == null) {
    _out(_fail('edit', '没有输入：请传文件路径或通过 stdin 管道输入 JSON'));
    exitCode = 2;
    return;
  }
  final output = _option(args, 'out');
  final patchesFile = _option(args, 'patches');
  final path = _option(args, 'path');
  try {
    final tree = parseTreeJson(text);
    if (tree == null) throw const FormatException('JSON 无法解析为编制树');

    final patches = <NodePatch>[];
    if (patchesFile != null && patchesFile.isNotEmpty) {
      final f = File(patchesFile);
      if (!f.existsSync()) throw FormatException('补丁文件不存在: $patchesFile');
      patches.addAll(parsePatchList(await f.readAsString()));
    }
    if (path != null && path.isNotEmpty) {
      patches.add(NodePatch(
        path: path,
        name: _option(args, 'name'),
        sidc: _option(args, 'sidc'),
        note: _option(args, 'note'),
      ));
    }
    if (patches.isEmpty) {
      _out(_fail('edit', '没有可应用的修改：需要 --path（配 --name/--note/--sidc）或 --patches'));
      exitCode = 2;
      return;
    }

    final res = applyPatches(tree, patches);
    if (!res.ok) {
      _out(_fail('edit', '补丁路径全部未命中，未做修改。检查 --path 是否与树中的名称逐字一致'));
      exitCode = 1;
      return;
    }
    // 改完照常走机械修复 + 校验，避免用户手工改出超长注释/带空格括号
    final fixed = OrbatAutoFix.apply(res.tree);
    final report = OrbatValidator.validate(fixed);
    final json = normalizeTreeJson(fixed);

    // 落盘：--out 优先；否则覆盖输入文件（有文件参数时）
    String? written;
    if (output != null && output.isNotEmpty) {
      await File(output).writeAsString(json);
      written = output;
    } else {
      final positional = _positionalArgs(args);
      if (positional.isNotEmpty && File(positional.first).existsSync()) {
        await File(positional.first).writeAsString(json);
        written = positional.first;
      }
    }
    if (written == null) {
      _out(_fail('edit', '没有输出路径：请加 --out <文件>（stdin 输入时无法覆盖原文件）'));
      exitCode = 2;
      return;
    }
    _out(_ok('edit', {
      'out': written,
      'applied': res.applied,
      'skipped': res.skipped,
      'nodeCount': fixed.count,
      'redCount': report.redCount,
      'warnCount': report.warnCount,
    }));
  } catch (e) {
    _out(_fail('edit', '$e'));
    exitCode = 1;
  }
}

Future<void> _cmdNormalize(List<String> args) async {
  final text = await _readInput(args);
  if (text == null) {
    _out(_fail('normalize', '没有输入'));
    exitCode = 2;
    return;
  }
  final levels = _option(args, 'command-levels') ?? '3';
  final output = _option(args, 'out');
  try {
    final tree = parseTreeJson(text);
    if (tree == null) throw const FormatException('JSON 无法解析为编制树');
    final json = normalizeTreeJson(tree, commandLevels: levels);
    if (output != null) {
      await File(output).writeAsString(json);
      _out(_ok('normalize', {
            'out': output,
            'chars': json.length,
            'nodeCount': tree.count,
          }));
    } else {
      // 归一化结果直接作为 data.json 输出（仍包在信封里）
      _out(_ok('normalize', {
            'nodeCount': tree.count,
            'json': jsonDecode(json),
          }));
    }
  } catch (e) {
    _out(_fail('normalize', '$e'));
    exitCode = 1;
  }
}

Future<void> _cmdRender(List<String> args) async {
  final inputPath = _option(args, 'in');
  final outBase = _option(args, 'out');
  final imagePath = _option(args, 'image');
  final textPath = _option(args, 'text');
  final whiteBg = _flag(args, 'white-bg', defaultValue: true);
  // --raw-names：保留原文称号/番号（对应界面「全中文输出」开关取消勾选）
  final forceChinese = !args.contains('--raw-names');

  // --out 可省略：省略时用输入目录 + 日期 + 根名（CLI 默认输入目录）
  final settings = await SettingsStore.load();
  final pipeline = OrbatPipeline(
    apiKey: settings.apiKey,
    model: settings.model,
    renderScriptPath: settings.renderScriptPath,
    whiteBackground: whiteBg,
    forceChinese: forceChinese,
  );

  OrbatNode? tree;
  String? sourceInfo;

  // 三种输入：--image（识图）/ --text（纯文本）/ --in（JSON 文件）
  if (imagePath != null) {
    final f = File(imagePath);
    if (!f.existsSync()) {
      _out(_fail('render', '图片不存在: $imagePath'));
      exitCode = 2;
      return;
    }
    final extra = textPath != null && File(textPath).existsSync()
        ? File(textPath).readAsStringSync()
        : null;
    final r = await pipeline.fromImage(f, extraText: extra);
    if (r.tree == null) {
      _out(_fail('render', r.error ?? '识图失败'));
      exitCode = 1;
      return;
    }
    tree = r.tree;
    sourceInfo = 'image:${f.path}';
  } else if (textPath != null) {
    final f = File(textPath);
    if (!f.existsSync()) {
      _out(_fail('render', '文本文件不存在: $textPath'));
      exitCode = 2;
      return;
    }
    final r = await pipeline.fromText(f.readAsStringSync());
    if (r.tree == null) {
      _out(_fail('render', r.error ?? '生成失败'));
      exitCode = 1;
      return;
    }
    tree = r.tree;
    sourceInfo = 'text:${f.path}';
  } else if (inputPath != null) {
    final f = File(inputPath);
    if (!f.existsSync()) {
      _out(_fail('render', 'JSON 不存在: $inputPath'));
      exitCode = 2;
      return;
    }
    tree = parseTreeJson(f.readAsStringSync());
    if (tree == null) {
      _out(_fail('render', 'JSON 无法解析为编制树'));
      exitCode = 1;
      return;
    }
    sourceInfo = 'json:${f.path}';
  } else {
    // stdin
    final text = await _readInput(args);
    if (text == null) {
      _out(_fail('render', '没有输入：用 --in/--image/--text 或 stdin'));
      exitCode = 2;
      return;
    }
    tree = parseTreeJson(text);
    if (tree == null) {
      _out(_fail('render', 'stdin 的内容不是合法编制 JSON'));
      exitCode = 1;
      return;
    }
    sourceInfo = 'stdin';
  }

  // 确定输出基名：显式 --out 优先；否则用输入目录 + 日期 + 根名
  final resolvedBase = outBase ?? () {
    final inputDir = (inputPath ?? imagePath ?? textPath) != null
        ? File((inputPath ?? imagePath ?? textPath)!).parent.path
        : _defaultCliOutputDir();
    final name = tree!.uniqueDesignation.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    return '$inputDir${Platform.pathSeparator}${stamp}_$name';
  }();
  final r = await pipeline.render(tree!, outputBase: resolvedBase);
  _out(_ok('render', {
        'outputBase': resolvedBase,
        'source': sourceInfo,
        'nodeCount': tree.count,
        'ok': r.ok,
        'png': r.pngPath,
        'svg': r.svgPath,
        'error': r.error,
        'elapsedMs': r.elapsed.inMilliseconds,
      }));
  if (!r.ok) exitCode = 1;
}

Future<void> _cmdGenerate(List<String> args) async {
  final imagePath = _option(args, 'image');
  final textPath = _option(args, 'text');
  final outJson = _option(args, 'out');

  if (imagePath == null && textPath == null) {
    _out(_fail('generate', '需要 --image <图片> 或 --text <文本文件>'));
    exitCode = 2;
    return;
  }

  final settings = await SettingsStore.load();
  // 模式三（Agent 全权）下软件不配 API：generate 必须给出明确指引。
  if (settings.apiKey.trim().isEmpty) {
    _out(_fail('generate',
        '未配置 API Key，无法执行识图。'
        '若你是 AI Agent（模式三），请用自己的模型读图生成 JSON，'
        '再调用 parse/validate 校验、render 出图；'
        '可用 `prompts` 命令导出本软件的工作流提示词。'
        '或设置 DEEPSEEK_API_KEY 环境变量 / 在 GUI 设置里填 Key。'));
    exitCode = 2;
    return;
  }
  final pipeline = OrbatPipeline(
    apiKey: settings.apiKey,
    model: settings.model,
    renderScriptPath: settings.renderScriptPath,
  );

  PipelineResult r;
  if (imagePath != null) {
    final f = File(imagePath);
    if (!f.existsSync()) {
      _out(_fail('generate', '图片不存在: $imagePath'));
      exitCode = 2;
      return;
    }
    final extra = _option(args, 'extra');
    r = await pipeline.fromImage(f, extraText: extra);
  } else {
    final f = File(textPath!);
    if (!f.existsSync()) {
      _out(_fail('generate', '文本文件不存在: $textPath'));
      exitCode = 2;
      return;
    }
    r = await pipeline.fromText(f.readAsStringSync());
  }

  if (r.tree == null) {
    _out(_fail('generate', r.error ?? '生成失败'));
    exitCode = 1;
    return;
  }

  final json = normalizeTreeJson(r.tree!);
  if (outJson != null) {
    await File(outJson).writeAsString(json);
  }
  _out(_ok('generate', {
        'nodeCount': r.tree!.count,
        'depth': r.tree!.maxDepth,
        'redCount': r.report?.redCount ?? 0,
        'warnCount': r.report?.warnCount ?? 0,
        'aiAttempts': r.aiAttempts,
        'repairRounds': r.repairRounds,
        // v0.4：名称与 SIDC 不一致、已按名称自动修正的条数
        'sidcAuditFixed': r.auditIssues.length,
        'elapsedMs': r.elapsed.inMilliseconds,
        'outJson': outJson,
        if (outJson == null) 'json': jsonDecode(json),
      }));
}

Future<void> _cmdSelfCheck(List<String> args) async {
  final settings = await SettingsStore.load();
  final r = await SelfCheck.run(
    renderScriptPath: settings.renderScriptPath,
    apiKey: settings.apiKey,
    // selfcheck --smoke：真渲染一次，验证"能不能出图"（约 15-25 秒）
    smokeRender: args.contains('--smoke'),
  );
  _out(_ok('selfcheck', {
        'allOk': r.allOk,
        'failCount': r.failCount,
        'warnCount': r.warnCount,
        'items': r.items
            .map((i) => {
                  'name': i.name,
                  'level': i.level,
                  'detail': i.detail,
                  'fix': i.fix,
                })
            .toList(),
      }));
  if (!r.allOk) exitCode = 3;
}

Future<void> _cmdUsage(List<String> args) async {
  final s = await UsageStore.summary();
  final recent = await UsageStore.recent(limit: 30);
  _out(_ok('usage', {
        'today': {
          'calls': s.todayCalls,
          'in': s.todayIn,
          'out': s.todayOut,
          'total': s.todayTokens,
        },
        'month': {
          'calls': s.monthCalls,
          'in': s.monthIn,
          'out': s.monthOut,
          'total': s.monthTokens,
        },
        'totalCalls': s.totalCalls,
        'recent': recent
            .map((e) => {
                  'time': e.time.toIso8601String(),
                  'scene': e.scene,
                  'in': e.promptTokens,
                  'out': e.completionTokens,
                  'ms': e.ms,
                  'model': e.model,
                })
            .toList(),
      }));
}

Future<void> _cmdBatch(List<String> args) async {
  final imageDir = _option(args, 'dir');
  final outDir = _option(args, 'out-dir');
  final recursive = args.contains('--recursive');

  if (imageDir == null) {
    _out(_fail('batch', '需要 --dir <图片目录>'));
    exitCode = 2;
    return;
  }
  final dir = Directory(imageDir);
  if (!dir.existsSync()) {
    _out(_fail('batch', '目录不存在: $imageDir'));
    exitCode = 2;
    return;
  }

  final exts = {'.png', '.jpg', '.jpeg', '.webp', '.bmp'};
  final files = dir
      .listSync(recursive: recursive)
      .whereType<File>()
      .where((f) => exts.contains(_ext(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    _out(_fail('batch', '目录里没有图片'));
    exitCode = 2;
    return;
  }

  // 确保输出目录存在
  if (outDir != null) {
    await Directory(outDir).create(recursive: true);
  }

  final settings = await SettingsStore.load();
  final whiteBg = _flag(args, 'white-bg', defaultValue: true);
  final results = <Map<String, dynamic>>[];

  for (var i = 0; i < files.length; i++) {
    final f = files[i];
    _err('[${i + 1}/${files.length}] ${f.path}');
    final pipeline = OrbatPipeline(
      apiKey: settings.apiKey,
      model: settings.model,
      renderScriptPath: settings.renderScriptPath,
      whiteBackground: whiteBg,
    );

    final name = _baseName(f.path);
    final targetDir = outDir ?? f.parent.path;
    final outputBase = '$targetDir${Platform.pathSeparator}${name}';

    try {
      final gen = await pipeline.fromImage(f);
      if (gen.tree == null) {
        results.add({
          'file': f.path,
          'ok': false,
          'error': gen.error ?? '识图失败',
        });
        continue;
      }
      final jsonPath = '$outputBase.json';
      await File(jsonPath).writeAsString(gen.rawJson ?? normalizeTreeJson(gen.tree!));
      final r = await pipeline.render(gen.tree!, outputBase: outputBase);
      results.add({
        'file': f.path,
        'ok': r.ok,
        'nodeCount': gen.tree!.count,
        'json': jsonPath,
        'png': r.pngPath,
        'svg': r.svgPath,
        'error': r.error,
      });
    } catch (e) {
      results.add({'file': f.path, 'ok': false, 'error': e.toString()});
    }
  }

  final okCount = results.where((r) => r['ok'] == true).length;
  _out(_ok('batch', {
        'total': results.length,
        'success': okCount,
        'failed': results.length - okCount,
        'results': results,
      }));
  if (okCount < results.length) exitCode = 3;
}

/// 单独重跑某张图里识别失败的切片
Future<void> _cmdRetryTile(List<String> args) async {
  final imagePath = _option(args, 'image');
  final outJson = _option(args, 'out');
  final row = int.tryParse(_option(args, 'row') ?? '');
  final col = int.tryParse(_option(args, 'col') ?? '');
  final rows = int.tryParse(_option(args, 'rows') ?? '');
  final cols = int.tryParse(_option(args, 'cols') ?? '');

  if (imagePath == null || row == null || col == null || rows == null || cols == null) {
    _out(_fail('retry-tile',
        '需要 --image <图> --row N --col N --rows N --cols N [--out <json>]'));
    exitCode = 2;
    return;
  }
  final f = File(imagePath);
  if (!f.existsSync()) {
    _out(_fail('retry-tile', '图片不存在: $imagePath'));
    exitCode = 2;
    return;
  }

  // 直接裁出那块 + 识别，输出子树 JSON
  final tile = prepareTileFromFile(f, row, col, rows, cols);
  final settings = await SettingsStore.load();
  final r = await OrbatPipeline(
    apiKey: settings.apiKey,
    model: settings.model,
    renderScriptPath: settings.renderScriptPath,
  ).fromImage(tile);

  if (r.tree == null) {
    _out(_fail('retry-tile', r.error ?? '重跑失败'));
    exitCode = 1;
    return;
  }
  final json = normalizeTreeJson(r.tree!);
  if (outJson != null) await File(outJson).writeAsString(json);
  _out(_ok('retry-tile', {
        'row': row,
        'col': col,
        'nodeCount': r.tree!.count,
        'root': r.tree!.uniqueDesignation,
        'outJson': outJson,
        if (outJson == null) 'json': jsonDecode(json),
      }));
}

String _ext(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i);
}

String _baseName(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final i = name.lastIndexOf('.');
  return i < 0 ? name : name.substring(0, i);
}

/// 导出软件内置的工作流提示词（模式三：Agent 全权，无需软件配 API）
Future<void> _cmdPrompts(List<String> args) async {
  final which = _option(args, 'type') ?? 'all';
  final outFile = _option(args, 'out');
  final prompts = <String, dynamic>{
    '识图工作流（分块读图，agent 三段式）': kTileSystemPrompt,
    '文字/修复（完整 SIDC 规范）': kOrbatSystemPrompt,
  };
  Map<String, dynamic> selected;
  if (which == 'tile') {
    selected = {'识图工作流': kTileSystemPrompt};
  } else if (which == 'full') {
    selected = {'完整规范': kOrbatSystemPrompt};
  } else {
    selected = prompts;
  }

  String? savedPath;
  if (outFile != null) {
    final buf = StringBuffer();
    selected.forEach((k, v) {
      buf.writeln('===== $k =====');
      buf.writeln(v);
      buf.writeln();
    });
    await File(outFile).writeAsString(buf.toString());
    savedPath = outFile;
  }

  _out(_ok('prompts', {
        'type': which,
        'count': selected.length,
        'out': savedPath,
        'prompts': selected,
        'note': '模式三：Agent 用这些提示词调用自己的模型，再用 parse/validate/render 完成出图',
      }));
}

Future<void> _cmdConfig(List<String> args) async {
  final s = await SettingsStore.load();
  _out(_ok('config', {
        'configVersion': s.configVersion,
        'currentConfigVersion': SettingsStore.currentConfigVersion,
        'model': s.model,
        'knownModels': SettingsStore.knownModels,
        'hasApiKey': s.apiKey.isNotEmpty,
        'apiKeyFingerprint': AppLogger.keyFingerprint(s.apiKey),
        'whiteBackground': s.whiteBackground,
        'renderScriptPath': s.renderScriptPath,
        'lastDir': s.lastDir,
      }));
}

// ---------- 工具 ----------

/// 取 --key value 或 --key=value
String? _option(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--$key' && i + 1 < args.length) return args[i + 1];
    if (a.startsWith('--$key=')) return a.substring(key.length + 3);
  }
  return null;
}

/// 布尔开关：--white-bg=false / --no-white-bg
bool _flag(List<String> args, String key, {required bool defaultValue}) {
  if (args.contains('--no-$key')) return false;
  final v = _option(args, key);
  if (v == null) return defaultValue;
  return v != '0' && v.toLowerCase() != 'false';
}

const _help = '''
ORBAT CLI —— 编制图生成器的命令行接口

用法:
  orbat.bat <命令> [选项] [文件]

命令:
  parse      解析 JSON，输出节点数/层级/根名
  validate   校验 JSON，输出全部问题（红牌时 exit=3）
  audit      一致性审计 + 跨父同名扫描（模型码与名称不自洽时给建议值）
  edit       按路径改单位名称/注释/SIDC（补丁式，不重写整棵树）
  normalize  归一化为渲染器要求的 7 键结构
  render     出图（PNG + SVG）
  generate   从图片或文字生成编制 JSON（调 AI）
  selfcheck  检查本机依赖（node/浏览器/脚本/网络）
  usage      查看 API 调用次数与 token 消耗
  config     查看当前配置（API Key 只显示指纹）
  batch      批量识图+出图（目录里所有图片）
  retry-tile 单独重跑某个识别失败的图块
  prompts    导出软件内置工作流提示词（模式三给 Agent 用，零 API）

输入方式:
  所有接受 JSON 的命令都支持：
    · 文件参数:  orbat.bat validate 编制.json
    · stdin 管道: cat 编制.json | orbat.bat validate
  优先级：stdin > 文件参数

常用选项:
  --in <json>           render 的输入 JSON
  --image <img>         generate/render 的输入图片
  --text <txt>          generate/render 的输入文本
  --extra <str>         generate 的补充说明
  --out <path>          输出路径/基名
  --raw-names           generate 时保留原文称号/番号（默认译成中文）
  --smoke               selfcheck 时真渲染一次，验证出图链路（约 15-25 秒）
  --no-white-bg         render 输出透明底 PNG
  --command-levels 3    normalize 的 commandLevels

输出约定:
  stdout 永远是一个 JSON 对象: {"ok":bool,"command":..,"data":{..},"error":..}
  stderr 只放诊断信息
  exit code: 0=成功 1=执行失败 2=参数错误 3=校验/自检发现问题

示例:
  orbat.bat validate 编制.json
  orbat.bat render --in 编制.json --out 输出名 --no-white-bg
  orbat.bat generate --image 图.png --out 编制.json
  orbat.bat generate --image 图.png --raw-names --out 原文.json
  orbat.bat audit 编制.json
  orbat.bat edit 编制.json --path "根/第1旅/第2营" --name "第2营" --note "Kensington"
  orbat.bat selfcheck --smoke
  orbat.bat selfcheck
''';


/// CLI 入口：跑完强制退出。
/// Dart CLI 里即使不读 stdin，事件循环也可能因为全局订阅不结束，
/// 所以显式 exit 保证进程立即返回（外部 agent 才能拿到结果）。
Future<void> main(List<String> args) async {
  await _runMain(args);
  exit(exitCode);
}
