/// ORBAT CLI —— 供外部 AI Agent 调用的命令行接口
///
/// 设计约束：
///   · stdout **只输出 JSON**，一行或一个 JSON 对象，机器可直接 json.loads
///   · 所有诊断/进度/日志走 stderr，绝不污染 stdout
///   · 输入优先读文件参数，也接受 stdin；支持的 JSON 命令优先 --in
///   · 任何错误都返回结构化的 {"ok":false,"error":...} 且 exit code ≠ 0
///
/// 用法见 `orbat.bat --help`
library;

import 'dart:convert';
import 'dart:io';

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../core/version.dart';
import '../core/auto_fix.dart';
import '../i18n/l10n.dart';
import '../i18n/tutorial_text.dart';
import '../core/dup_scan.dart';
import '../core/orbat.dart';
import '../core/orbat_schema.dart';
import '../core/patch_repair.dart';
import '../core/sidc_audit.dart';
import '../core/self_check.dart';
import '../core/usage_store.dart';
import '../pipeline.dart';
import '../render/renderer.dart'
    show RenderQuality, RenderResult, downscalePngToWidth;
import '../ai/image_prep.dart';
import '../ai/prompt.dart';
import '../services/settings_store.dart';

/// 机器可读的 CLI 协议版本；信封/字段语义变化时递增。
const int kCliProtocolVersion = 1;

void _out(Map<String, dynamic> obj) {
  stdout.writeln(jsonEncode(obj));
}

void _err(String msg) {
  stderr.writeln('[orbat-cli] $msg');
}

Map<String, dynamic> _ok(
  String cmd,
  Map<String, dynamic> data, {
  bool ok = true,
}) {
  AppLogger.instance.info('cli', ok ? '完成: $cmd' : '失败: $cmd');
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
  final result = <String, dynamic>{
    'ok': ok,
    'command': cmd,
    'data': {
      ...data,
      // 明确宣告给 Agent：产物生成目标目录（绝对路径）
      'outputDir': d,
      // 日志位置：正常日志 14 天；错误报告另存，不随正常日志删除。
      'logs': _logInfo(),
    },
  };
  // 顶层 ok=false 时补一个便于宿主直接读取的错误字段。
  if (!ok && data['error'] is String && (data['error'] as String).isNotEmpty) {
    result['error'] = data['error'];
  }
  return result;
}

/// 当前日志/错误报告位置，供 Agent 直接读取。
Map<String, dynamic> _logInfo() {
  final log = AppLogger.instance;
  return <String, dynamic>{
    'enabled': log.isEnabled,
    'normalDir': log.logDirPath,
    'normalCurrent': log.currentLogPath,
    'normalKeepDays': AppLogger.keepDays,
    'errorDir': log.errorReportDirPath,
    'errorRetention': 'persistent',
  };
}

/// CLI 兜底输出目录（命令自身已优先用输入目录）。
///
/// 0.3.2 起统一为 exe 同级「输出文件存档\」：与 GUI 一致、不写桌面根，
/// 且对 Agent 调用方而言目录位置可预测（就在 orbat-cli.exe 旁边）。
String _defaultCliOutputDir() => ensureArchiveDir();

/// 失败信封：同步落一份独立错误报告（含正常日志尾部），并给出路径。
///
/// 报告与正常日志分开存放，正常日志 14 天自动清理，错误报告不自动删除。
Map<String, dynamic> _fail(String cmd, String msg, {String? reportPath}) {
  AppLogger.instance.warn('cli', '$cmd 失败: $msg');
  final String? report =
      reportPath ?? AppLogger.instance.saveErrorReportSync('cli-$cmd', msg);
  return {
    'ok': false,
    'command': cmd,
    'error': msg,
    if (report != null) 'errorReport': report,
    'logs': _logInfo(),
  };
}

/// 去掉 UTF-8 BOM；Windows 记事本/PowerShell 管道偶尔会带。
String _stripBom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

/// 读取输入：优先文件参数（避免无管道时等待 stdin），否则读 stdin。
Future<String?> _readInput(List<String> args) async {
  // 找到第一个非选项参数（注意：选项的值也是非选项参数，需排除）
  final positional = _positionalArgs(args);

  if (positional.isNotEmpty) {
    // 有文件参数 → 直接读文件，完全不碰 stdin（避免事件循环挂住）
    final f = File(positional.first);
    if (f.existsSync()) return _stripBom(f.readAsStringSync());
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
    return _stripBom(chunks.join('\n'));
  } catch (_) {
    return null;
  }
}

/// 提取位置参数（排除 --key value 里的 value）
List<String> _positionalArgs(List<String> args) {
  const valueOptions = {
    'in', 'out', 'image', 'text', 'extra', 'command-levels',
    // edit/audit 的定位与补丁参数（否则他们的值会被误当成位置文件）
    'path', 'patches', 'name', 'note', 'sidc',
    // batch / tutorial / prompts / retry-tile 的值参数
    'dir', 'out-dir', 'lang', 'type', 'row', 'col', 'rows', 'cols',
    // 允许 --white-bg false 这种写法
    'white-bg',
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
  // 不改变 cwd：相对路径按调用方当前目录解析，符合常见 CLI 约定。
  if (args.isNotEmpty && (args.first == '--version' || args.first == '-v')) {
    _out({
      'ok': true,
      'command': 'version',
      'data': {'version': kAppVersion, 'protocol': kCliProtocolVersion},
    });
    return;
  }

  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _err(_help);
    _out({
      'ok': true,
      'command': 'help',
      'data': {'usage': _help}
    });
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
        await _cmdAudit(rest);
        break;
      case 'edit':
        await _cmdEdit(rest);
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
      case 'tutorial':
        await _cmdTutorial(rest);
        break;
      case 'prompts':
        await _cmdPrompts(rest);
        break;
      case 'logs':
        await _cmdLogs(rest);
        break;
      case 'schema':
        await _cmdSchema(rest);
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
    AppLogger.instance.error('cli', '异常: $e', e, st);
    final String? report = AppLogger.instance.saveErrorReportSync(
      'cli-$cmd',
      '$e',
      error: e,
      stack: st,
    );
    _out(_fail(cmd, '$e', reportPath: report));
    exitCode = 1;
  }
}

// ---------- 命令实现 ----------

Future<void> _cmdParse(List<String> args) async {
  final text = await _readInputOrIn(args);
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
  final text = await _readInputOrIn(args);
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
    return _stripBom(await f.readAsString());
  }
  return _readInput(args);
}

/// parse/validate/normalize 用：支持 --in，但缺文件时返回 null 而不是抛异常，
/// 保持这些命令原有的“没有输入 → exit 2”语义。
Future<String?> _readInputOrIn(List<String> args) async {
  final inPath = _option(args, 'in');
  if (inPath != null && inPath.isNotEmpty) {
    final f = File(inPath);
    if (!f.existsSync()) return null;
    return _stripBom(await f.readAsString());
  }
  return _readInput(args);
}

/// audit —— 一致性审计 + 结构校验 + 跨父同名扫描（只读，不改文件）
Future<void> _cmdAudit(List<String> args) async {
  final strict = args.contains('--strict') || args.contains('--fail-on-red');
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
      'strict': strict,
      'passed': !strict || report.ok,
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
      'duplicates':
          dups.map((d) => {'name': d.displayName, 'paths': d.paths}).toList(),
      'redCount': report.redCount,
      'warnCount': report.warnCount,
      'issues': report.issues
          .map((i) => {'level': i.level, 'path': i.path, 'message': i.message})
          .toList(),
    }));
    if (strict && !report.ok) exitCode = 3;
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
      _out(_fail(
          'edit', '没有可应用的修改：需要 --path（配 --name/--note/--sidc）或 --patches'));
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
    final data = <String, dynamic>{
      'applied': res.applied,
      'skipped': res.skipped,
      'nodeCount': fixed.count,
      'redCount': report.redCount,
      'warnCount': report.warnCount,
    };
    if (written != null) {
      data['out'] = written;
    } else {
      // stdin 输入且没有 --out：把结果回给调用方，便于管道继续 validate/render。
      data['json'] = jsonDecode(json);
    }
    _out(_ok('edit', data));
  } catch (e) {
    _out(_fail('edit', '$e'));
    exitCode = 1;
  }
}

Future<void> _cmdNormalize(List<String> args) async {
  final text = await _readInputOrIn(args);
  if (text == null) {
    _out(_fail('normalize', '没有输入：请传文件路径、--in 或通过 stdin 输入 JSON'));
    exitCode = 2;
    return;
  }
  final levels = _option(args, 'command-levels') ?? '3';
  final output = _option(args, 'out');
  try {
    var tree = parseTreeJson(text);
    if (tree == null) throw const FormatException('JSON 无法解析为编制树');
    var echelonFixed = 0;
    if (args.contains('--adapt-for-render')) {
      // 渲染归一化时按名称兜底修正梯队段，避免「师部及师部营」画错图标。
      final fix = OrbatAutoFix.fixEchelonReport(tree);
      tree = fix.tree;
      echelonFixed = fix.fixed;
    }
    final json = normalizeTreeJson(tree, commandLevels: levels);
    final data = <String, dynamic>{
      'nodeCount': tree.count,
      'echelonFixed': echelonFixed,
    };
    if (output != null) {
      await File(output).writeAsString(json);
      data['out'] = output;
      data['chars'] = json.length;
    } else {
      // 归一化结果直接作为 data.json 输出（仍包在信封里）
      data['json'] = jsonDecode(json);
    }
    _out(_ok('normalize', data));
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
    apiBaseUrl: settings.apiBaseUrl,
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
    tree = parseTreeJson(_stripBom(f.readAsStringSync()));
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

  // 梯队兜底由 pipeline.render 内部完成：只修渲染副本，并通过 notices 返回
  // 修正条数；源 tree 保持不动。这里不再预先修改，否则 notice 永远是 0。
  final root = tree!;

  // validate-only：只做结构解析 + 校验，不启动浏览器、不写 PNG/SVG。
  if (args.contains('--validate-only')) {
    final report = OrbatValidator.validate(root);
    final levels = root.commandLevels.trim() == '2' ? '2' : '3';
    _out(_ok('render', {
      'source': sourceInfo,
      'nodeCount': report.nodeCount,
      'depth': report.depth,
      'redCount': report.redCount,
      'warnCount': report.warnCount,
      'ok': report.ok,
      'deliverable': report.ok,
      'commandLevelsInput': root.commandLevels,
      'commandLevelsOutput': levels,
      'outputDir': (inputPath ?? imagePath ?? textPath) != null
          ? File((inputPath ?? imagePath ?? textPath)!).parent.path
          : _defaultCliOutputDir(),
      'issues': report.issues
          .map((i) => {
                'level': i.level,
                'path': i.path,
                'message': i.message,
              })
          .toList(),
      'render': {
        'ok': false,
        'skipped': true,
        'reason': 'validate-only',
      },
    }));
    exitCode = report.ok ? 0 : 3;
    return;
  }

  // 确定输出基名：显式 --out 优先；否则用输入目录 + 日期 + 根名
  final resolvedBase = outBase ??
      () {
        final inputDir = (inputPath ?? imagePath ?? textPath) != null
            ? File((inputPath ?? imagePath ?? textPath)!).parent.path
            : _defaultCliOutputDir();
        final name =
            root.uniqueDesignation.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final stamp = DateTime.now().toIso8601String().substring(0, 10);
        return '$inputDir${Platform.pathSeparator}${stamp}_$name';
      }();
  final maxWidth = int.tryParse(_option(args, 'max-width') ?? '') ?? 4096;
  final rendered = await _renderWithLayout(
    pipeline,
    root,
    resolvedBase,
    maxWidth: maxWidth,
    whiteBackground: whiteBg,
  );
  final r = rendered.result;
  final data = <String, dynamic>{
    'outputBase': resolvedBase,
    'source': sourceInfo,
    'nodeCount': root.count,
    'ok': r.ok,
    'png': r.pngPath,
    'svg': r.svgPath,
    'error': r.error ?? (r.ok ? null : '渲染失败'),
    'elapsedMs': r.elapsed.inMilliseconds,
    'notices': r.notices,
    'layout': rendered.layout,
    if (r.quality != null) 'quality': r.quality!.toJson(),
  };
  // render 的成败必须同时反映在顶层 ok 和进程退出码上；
  // 校验红牌仍走 validate 的“报告”语义，不受此影响。
  _out(_ok('render', data, ok: r.ok));
  if (!r.ok) exitCode = 1;
}

/// 出图并在超宽时尝试 `commandLevels:"2"`；只保留更窄的结果。
///
/// 不改变源 tree：commandLevels 通过 pipeline 的 override 只作用于渲染副本。
/// 返回渲染结果与 `layout` 决策，供 Agent 判断是否“已优化/仍建议桌面查看”。
Future<({RenderResult result, Map<String, dynamic> layout})> _renderWithLayout(
  OrbatPipeline pipeline,
  OrbatNode root,
  String outputBase, {
  int maxWidth = 4096,
  bool whiteBackground = true,
}) async {
  final String inputLevels = root.commandLevels.trim();
  final String effectiveInput = inputLevels == '2' ? '2' : '3';
  var result = await pipeline.render(root, outputBase: outputBase);
  final layout = <String, dynamic>{
    'commandLevelsInput': inputLevels,
    'commandLevelsOutput': effectiveInput,
    'width': result.quality?.width ?? 0,
    'height': result.quality?.height ?? 0,
    'strategy': 'default',
  };

  final int width = result.quality?.width ?? 0;
  final bool tooWide = width > maxWidth;
  if (!result.ok || !tooWide) {
    return (result: result, layout: layout);
  }

  if (effectiveInput != '2') {
    // 只有“3 已超宽”才尝试 2；2 不一定更窄，必须比较后保留更窄者。
    final String tmpBase = '${outputBase}.__cl2';
    final RenderResult second = await pipeline.render(
      root,
      outputBase: tmpBase,
      commandLevelsOverride: '2',
    );
    final int secondWidth = second.quality?.width ?? 0;

    if (second.ok && secondWidth > 0 && secondWidth < width) {
      for (final String ext in const <String>['.png', '.svg']) {
        final File orig = File('$outputBase$ext');
        final File tmp = File('$tmpBase$ext');
        try {
          if (await orig.exists()) await orig.delete();
          if (await tmp.exists()) await tmp.rename('$outputBase$ext');
        } catch (_) {}
      }
      result = RenderResult(
        ok: second.ok,
        svgPath: '$outputBase.svg',
        pngPath: '$outputBase.png',
        error: second.error,
        elapsed: second.elapsed,
        logPath: second.logPath,
        quality: second.quality,
        notices: second.notices,
      );
      layout['commandLevelsOutput'] = '2';
      layout['strategy'] = 'commandLevels2';
      layout['width'] = secondWidth;
      layout['height'] = second.quality?.height ?? 0;
    } else {
      for (final String ext in const <String>['.png', '.svg']) {
        try {
          final File tmp = File('$tmpBase$ext');
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
      layout['strategy'] = 'keep-3';
    }
  }

  // 最后手段：仍超宽时等比缩成整图（不分页），并保留提示。
  if (result.ok &&
      result.pngPath != null &&
      (result.quality?.width ?? 0) > maxWidth) {
    final int before = result.quality?.width ?? 0;
    final RenderQuality q = await downscalePngToWidth(
      result.pngPath!,
      maxWidth: maxWidth,
      whiteBackground: whiteBackground,
    );
    if (q.ok && q.width > 0) {
      result = RenderResult(
        ok: result.ok,
        svgPath: result.svgPath,
        pngPath: result.pngPath,
        error: result.error,
        elapsed: result.elapsed,
        logPath: result.logPath,
        quality: q,
        notices: result.notices,
      );
      layout['strategy'] = 'downscale';
      layout['width'] = q.width;
      layout['height'] = q.height;
      layout['scale'] =
          before == 0 ? 1 : double.parse((q.width / before).toStringAsFixed(3));
    }
  }

  if ((result.quality?.width ?? 0) > maxWidth) {
    layout['warning'] = '建议桌面查看';
  }
  return (result: result, layout: layout);
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
    _out(_fail(
        'generate',
        '未配置 API Key，无法执行识图。'
            '若你是 AI Agent（模式三），请用自己的模型读图生成 JSON，'
            '再调用 parse/validate 校验、render 出图；'
            '可用 `prompts` 命令导出本软件的工作流提示词。'
            '或设置 DEEPSEEK_API_KEY / OPENAI_API_KEY 环境变量，'
            '或在 GUI 设置里填 Key 与 OpenAI 兼容 API 地址。'));
    exitCode = 2;
    return;
  }
  final pipeline = OrbatPipeline(
    apiKey: settings.apiKey,
    model: settings.model,
    renderScriptPath: settings.renderScriptPath,
    apiBaseUrl: settings.apiBaseUrl,
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
    apiBaseUrl: settings.apiBaseUrl,
    apiKey: settings.apiKey,
    // selfcheck --smoke：真渲染一次，验证"能不能出图"（约 15-25 秒）
    smokeRender: args.contains('--smoke'),
    outputDir: _defaultCliOutputDir(),
    mode: settings.mode,
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
  final bool validateOnly = args.contains('--validate-only');
  final bool rescan = !args.contains('--no-rescan');
  final int maxWidth = int.tryParse(_option(args, 'max-width') ?? '') ?? 4096;
  final results = <Map<String, dynamic>>[];
  final processed = <String>{};
  var pending = files;
  var rescanPasses = 0;

  while (pending.isNotEmpty) {
    for (var i = 0; i < pending.length; i++) {
      final f = pending[i];
      final key = f.absolute.path.toLowerCase();
      if (!processed.add(key)) continue;

      _err('[${processed.length}] ${f.path}');
      final pipeline = OrbatPipeline(
        apiKey: settings.apiKey,
        model: settings.model,
        renderScriptPath: settings.renderScriptPath,
        apiBaseUrl: settings.apiBaseUrl,
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
        await File(jsonPath)
            .writeAsString(gen.rawJson ?? normalizeTreeJson(gen.tree!));
        if (validateOnly) {
          final report = OrbatValidator.validate(gen.tree!);
          results.add({
            'file': f.path,
            'ok': report.ok,
            'nodeCount': report.nodeCount,
            'json': jsonPath,
            'redCount': report.redCount,
            'warnCount': report.warnCount,
            'issues': report.issues
                .map((i) => {
                      'level': i.level,
                      'path': i.path,
                      'message': i.message,
                    })
                .toList(),
            'render': {
              'ok': false,
              'skipped': true,
              'reason': 'validate-only',
            },
          });
          continue;
        }
        final rendered = await _renderWithLayout(
            pipeline, gen.tree!, outputBase,
            maxWidth: maxWidth, whiteBackground: whiteBg);
        final r = rendered.result;
        results.add({
          'file': f.path,
          'ok': r.ok,
          'nodeCount': gen.tree!.count,
          'json': jsonPath,
          'png': r.pngPath,
          'svg': r.svgPath,
          'error': r.error,
          'layout': rendered.layout,
          if (r.quality != null) 'quality': r.quality!.toJson(),
        });
      } catch (e) {
        results.add({'file': f.path, 'ok': false, 'error': e.toString()});
      }
    }

    if (!rescan || rescanPasses >= 2) break;
    rescanPasses++;
    // 批次运行期间新增的图片：再扫一次，按绝对路径去重，串行处理。
    final more = dir
        .listSync(recursive: recursive)
        .whereType<File>()
        .where((f) => exts.contains(_ext(f.path).toLowerCase()))
        .where((f) => !processed.contains(f.absolute.path.toLowerCase()))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (more.isNotEmpty) {
      _err('追加 ${more.length} 个新文件');
    }
    pending = more;
  }

  final okCount = results.where((r) => r['ok'] == true).length;
  _out(_ok('batch', {
    'total': results.length,
    'success': okCount,
    'failed': results.length - okCount,
    'rescanPasses': rescanPasses,
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

  if (imagePath == null ||
      row == null ||
      col == null ||
      rows == null ||
      cols == null) {
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
    apiBaseUrl: settings.apiBaseUrl,
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
/// tutorial —— 打印/导出内置纯文字教程（GUI 教程窗口用的是同一份文本）
///
/// 为什么要开这个命令：模式三的用户常常在 Agent 里问"下一步怎么做"，
/// 让 Agent 直接读这份文本比让用户翻 doc 更现实。默认跟随系统语言，
/// 可用 --lang zh|en 强制。
Future<void> _cmdTutorial(List<String> args) async {
  final lang = (_option(args, 'lang') ?? '').toLowerCase();
  if (lang == 'en') {
    L10n.setExplicit(AppLang.en);
  } else if (lang == 'zh') {
    L10n.setExplicit(AppLang.zh);
  } else {
    L10n.apply('');
  }
  final text = tutorialText();
  final outFile = _option(args, 'out');
  String? savedPath;
  if (outFile != null && outFile.isNotEmpty) {
    await File(outFile).writeAsString(text);
    savedPath = outFile;
  }
  _out(_ok('tutorial', {
    'revision': kTutorialRevision,
    'lang': L10n.isEn ? 'en' : 'zh',
    'out': savedPath,
    'chars': text.length,
    'text': text,
  }));
}

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

/// `logs`：返回日志路径；`--tail` 附带正常日志尾部，`--errors` 列出错误报告。
Future<void> _cmdLogs(List<String> args) async {
  final bool wantTail = args.contains('--tail');
  final bool wantErrors = args.contains('--errors');
  final info = _logInfo();

  String? tailText;
  if (wantTail) {
    final String? p = AppLogger.instance.currentLogPath;
    if (p != null) {
      final File f = File(p);
      if (f.existsSync()) {
        final List<String> lines = f.readAsStringSync().split('\n');
        tailText =
            (lines.length <= 80 ? lines : lines.sublist(lines.length - 80))
                .join('\n')
                .trim();
      }
    }
  }

  final List<Map<String, dynamic>> reports = <Map<String, dynamic>>[];
  if (wantErrors) {
    final String? dir = AppLogger.instance.errorReportDirPath;
    if (dir != null) {
      final Directory d = Directory(dir);
      if (d.existsSync()) {
        for (final File f in d.listSync().whereType<File>()) {
          reports.add(<String, dynamic>{
            'path': f.path,
            'modified': f.lastModifiedSync().toIso8601String(),
            'bytes': f.lengthSync(),
          });
        }
        reports.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
            (b['modified'] as String).compareTo(a['modified'] as String));
      }
    }
  }

  _out(_ok('logs', <String, dynamic>{
    ...info,
    if (tailText != null) 'tail': tailText,
    if (wantErrors) 'errorReports': reports,
  }));
}

/// `schema`：输出/导出 ORBAT JSON Schema（结构契约）。
Future<void> _cmdSchema(List<String> args) async {
  final String? out = _option(args, 'out');
  if (out != null && out.isNotEmpty) {
    await File(out).writeAsString(kOrbatSchemaJson, flush: true);
    _out(_ok('schema', <String, dynamic>{
      'version': kOrbatSchemaVersion,
      'out': out,
      'chars': kOrbatSchemaJson.length,
    }));
    return;
  }
  _out(_ok('schema', <String, dynamic>{
    'version': kOrbatSchemaVersion,
    'schema': jsonDecode(kOrbatSchemaJson),
    'note': '结构校验用；注释长度/SIDC 语义/重名等仍以 validate 为准。用 --out 导出文件。',
  }));
}

Future<void> _cmdConfig(List<String> args) async {
  final s = await SettingsStore.load();
  _out(_ok('config', {
    'version': kAppVersion,
    'protocol': kCliProtocolVersion,
    'configVersion': s.configVersion,
    'currentConfigVersion': SettingsStore.currentConfigVersion,
    'model': s.model,
    'apiBaseUrl': s.apiBaseUrl,
    'providerType': s.providerType,
    'knownModels': SettingsStore.knownModels,
    'hasApiKey': s.apiKey.isNotEmpty,
    'apiKeyFingerprint': AppLogger.keyFingerprint(s.apiKey),
    'whiteBackground': s.whiteBackground,
    'commandLevels': s.commandLevels,
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
  orbat.bat --version

命令:
  parse      解析 JSON，输出节点数/层级/根名
  validate   校验 JSON，输出全部问题（红牌时 exit=3）
  audit      一致性审计 + 跨父同名扫描（只读；--strict 时红牌 exit=3）
  edit       按路径改单位名称/注释/SIDC（补丁式，不重写整棵树）
  normalize  归一化为渲染器要求的 7 键结构
  render     出图（PNG + SVG）
  generate   从图片或文字生成编制 JSON（调 AI）
  selfcheck  检查本机依赖（node/浏览器/脚本/网络）
  usage      查看 API 调用次数与 token 消耗
  config     查看当前配置（API Key 只显示指纹）
  tutorial   打印/导出内置纯文字教程
  batch      批量识图+出图（目录里所有图片）
  retry-tile 单独重跑某个识别失败的图块
  prompts    导出软件内置工作流提示词（模式三给 Agent 用，零 API）
  logs       查看日志/错误报告位置（--tail 看日志尾部，--errors 列错误报告）
  schema     输出/导出 ORBAT JSON Schema（结构契约）

输入方式:
  · --in 文件:  orbat.bat validate --in 编制.json
  · 文件参数:   orbat.bat validate 编制.json
  · stdin 管道: cat 编制.json | orbat.bat validate
  优先级：--in > 文件参数 > stdin（没有文件参数时才读 stdin）

常用选项:
  --in <json>           JSON 命令的输入文件
  --out <path>          输出路径/基名
  --image <img>         generate/render 的输入图片
  --text <txt>          generate/render 的输入文本
  --extra <str>         generate 的补充说明
  --raw-names           generate 时保留原文称号/番号（默认译成中文）
  --adapt-for-render    normalize 时按名称修正梯队段（仅影响渲染副本）
  --command-levels 3    normalize 的 commandLevels
  --validate-only       render 只校验，不出图（exit 3=红牌）
  --max-width <px>      超宽自动尝试 commandLevels:"2" 的阈值（默认 4096）
  --no-rescan           batch 结束后不再扫描新增文件
  --no-white-bg         render 输出透明底 PNG
  --white-bg false      同上，显式关闭白底
  --smoke               selfcheck 时真渲染一次（约 15-25 秒）

edit/audit:
  --path <路径>         目标节点路径，如 "根/第1旅/第2营"
  --patches <json>      批量补丁文件
  --name/--note/--sidc  edit 要改的字段
  --strict              audit 红牌时 exit=3（默认只报告，不改变 exit）
  --fail-on-red         --strict 的别名

batch / tutorial / prompts / retry-tile:
  --dir <dir>           batch 输入目录
  --out-dir <dir>       batch 输出目录
  --recursive           batch 递归子目录
  --lang zh|en          tutorial 语言
  --type tile|full|all  prompts 类型
  --row/--col/--rows/--cols  retry-tile 切片参数

输出约定:
  stdout 永远是一个 JSON 对象: {"ok":bool,"command":..,"data":{..},"error":..}
  stderr 只放诊断信息
  data.logs 给出正常日志/错误报告路径；失败顶层另有 errorReport
  exit code: 0=成功 1=执行失败 2=参数错误 3=校验/自检/批量/audit --strict 发现问题
  render 失败时顶层 ok=false 且 exit=1；validate 红牌仍返回顶层 ok=true、exit=3

示例:
  orbat.bat --version
  orbat.bat validate --in 编制.json
  orbat.bat render --in 编制.json --out 输出名 --no-white-bg
  orbat.bat normalize --in 编制.json --adapt-for-render
  orbat.bat generate --image 图.png --out 编制.json
  orbat.bat generate --image 图.png --raw-names --out 原文.json
  orbat.bat audit 编制.json
  orbat.bat audit 编制.json --strict
  orbat.bat edit 编制.json --path "根/第1旅/第2营" --name "第2营" --note "Kensington"
  cat 编制.json | orbat.bat edit --path "根/第1旅" --name "第1旅"
  orbat.bat selfcheck --smoke
''';

/// CLI 入口：跑完强制退出。
/// Dart CLI 里即使不读 stdin，事件循环也可能因为全局订阅不结束，
/// 所以显式 exit 保证进程立即返回（外部 agent 才能拿到结果）。
Future<void> main(List<String> args) async {
  await _runMain(args);
  // 先把队列里的正常日志落盘，再强制退出，避免 Agent 读不到本次记录。
  await AppLogger.instance.close();
  exit(exitCode);
}
