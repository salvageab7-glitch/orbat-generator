import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/orbat.dart';
import '../core/version.dart';
import '../core/logger.dart';
import '../core/batch_queue.dart';
import '../core/tree_diff.dart';
import '../core/usage_store.dart';
import '../core/self_check.dart';
import '../pipeline.dart';
import '../ai/deepseek_client.dart';
import '../services/settings_store.dart';
import 'tree_view.dart';

/// 输入模式：资料为主 / 纯文本
enum InputMode { material, textOnly }

class HomePage extends StatefulWidget {
  final SettingsStore settings;
  final String? initialJsonPath;
  final bool autoRender;
  final String? initialImagePath;
  final bool autoGenerate;
  final VoidCallback onToggleTheme;

  const HomePage({
    super.key,
    required this.settings,
    required this.onToggleTheme,
    this.initialJsonPath,
    this.autoRender = false,
    this.initialImagePath,
    this.autoGenerate = false,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  File? _image;
  final _textCtrl = TextEditingController();
  InputMode _inputMode = InputMode.material;
  final _jsonCtrl = TextEditingController();

  OrbatNode? _tree;
  ValidationReport? _report;
  String _jsonText = '';
  /// 校验问题点击后要聚焦的树节点路径
  String? _focusPath;

  /// 批量任务队列
  BatchQueue? _batchQueue;
  bool _batchBusy = false;

  /// 用于结果对比的"上一版"树
  OrbatNode? _previousTree;
  TreeDiff? _lastDiff;
  String? _pngPath;
  String? _svgPath;

  bool _busy = false;
  String _stage = '就绪';
  final List<String> _log = [];

  // ---- 出图进度 ----
  bool _rendering = false;
  String _renderStageName = '准备';
  double _renderProgress = 0;
  Duration _renderElapsed = Duration.zero;
  final List<String> _renderLog = [];
  Timer? _renderTicker;
  String? _lastRenderLogPath;

  @override
  void dispose() {
    _renderTicker?.cancel();
    _textCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  /// 校验手工编辑后的 JSON，并把结果反映到树上
  void _validateEditedJson() {
    final parsed = parseTreeJson(_jsonText);
    if (parsed == null) {
      _snack('JSON 解析失败，请检查语法（括号、逗号、引号）');
      _appendLog('JSON 解析失败');
      return;
    }
    final report = OrbatValidator.validate(parsed);
    setState(() {
      _tree = parsed;
      _report = report;
    });
    _appendLog('手工 JSON 校验：${parsed.count} 节点，红牌 ${report.redCount}，软警告 ${report.warnCount}');
    _snack(report.ok
        ? '校验通过：${parsed.count} 节点，${report.warnCount} 条提示'
        : '发现 ${report.redCount} 个红牌错误，详见结构视图');
  }

  // ---------------------------------------------------------------- 动作

  void _appendLog(String msg) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _log.insert(0, '[$t] $msg');
      if (_log.length > 200) _log.removeLast();
    });
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'pdf', 'doc', 'docx'],
      allowMultiple: false,
      dialogTitle: '选择编制资料（图片 / PDF / DOC）',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    final ext = path.toLowerCase().split('.').last;
    final isDoc = const ['pdf', 'doc', 'docx'].contains(ext);

    if (isDoc) {
      // PDF/DOC 走视觉模型需要逐页转图，token 消耗会是图片的几倍到十几倍。
      // 先明确告知，由用户决定是否继续。
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('PDF / DOC 会显著增加消耗'),
          content: const Text(
            '把一个 PDF 交给视觉模型，需要逐页转成图片，'
            'token 消耗通常是单张图片的 3-10 倍，页数多的文件尤其明显。\n\n'
            '更省的做法：\n'
            '· 只截取需要的那一页导出为 PNG 再导入\n'
            '· 或把文字复制到「纯文本」模式\n\n'
            '当前版本尚未开放 PDF/DOC 的直接解析，'
            '继续会提示你改用截图或文本。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      if (go != true) return;
      _snack('请截图后导入图片，或把文字粘贴到「纯文本」模式');
      _appendLog('选择了 $ext 文件：解析功能未开放，已提示改用截图/文本');
      return;
    }

    setState(() {
      _image = File(path);
      widget.settings.lastDir = File(path).parent.path;
    });
    await widget.settings.save();
    _appendLog('已选择图片：${result.files.single.name}');
  }

  @override
  void initState() {
    super.initState();
    // 命令行直接识图：`启动.exe 图.png --generate`
    final img = widget.initialImagePath;
    if (img != null && img.isNotEmpty && widget.autoGenerate) {
      Timer(const Duration(milliseconds: 300), () async {
        if (!mounted) return;
        setState(() {
          _image = File(img);
          _inputMode = InputMode.material;
          widget.settings.lastDir = File(img).parent.path;
        });
        await widget.settings.save();
        _appendLog('命令行载入图片：${File(img).uri.pathSegments.last}');
        await _generate();
        // 若同时给了 --render，识图后接着出图
        if (widget.autoRender && mounted && _tree != null) {
          // 等一帧确保识图阶段的 setState 生效
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await _render();
        }
      });
    }
    final p = widget.initialJsonPath;
    if (p != null && p.isNotEmpty) {
      // 不用 addPostFrameCallback：实测命令行带 JSON 启动时，窗口在后台/不可见
      // 场景下第一帧可能迟迟不绘制，回调永不触发，导致"启动但不自动出图"。
      // 用 Timer 延迟执行，不依赖渲染帧。
      Timer(const Duration(milliseconds: 300), () async {
        await _loadJsonFile(p);
        if (widget.autoRender) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (mounted) await _render();
        }
      });
    }
    // 未配置 API Key 时的首次引导：双击启动才弹（命令行自动任务不打扰）。
    final hasCliTask = (widget.initialImagePath ?? '').isNotEmpty ||
        (widget.initialJsonPath ?? '').isNotEmpty;
    if (!hasCliTask && widget.settings.apiKey.trim().isEmpty) {
      Timer(const Duration(milliseconds: 600), _showApiKeyGuide);
    }
  }

  /// 首启无 Key 引导：告诉用户去哪申请、在哪填，一键直达设置。
  void _showApiKeyGuide() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('先配置 API Key'),
        content: const Text(
          '识图功能需要 DeepSeek API Key：\n\n'
          '1. 在 platform.deepseek.com 注册并创建 API Key；\n'
          '2. 点下方「打开设置」粘贴 Key；\n'
          '3. 出图功能不需要 Key，但需要安装 Node.js 24 或更高版本。\n\n'
          '之后可随时在右上角设置里修改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openSettings();
            },
            child: const Text('打开设置'),
          ),
        ],
      ),
    );
  }

  /// 读取一个编制 JSON 并展示（命令行启动、或「打开 JSON」都走这里）
  Future<void> _loadJsonFile(String path) async {
    try {
      final text = await File(path).readAsString();
      final parsed = parseTreeJson(text);
      if (parsed == null) {
        _snack('该文件不是有效的编制 JSON');
        return;
      }
      final report = OrbatValidator.validate(parsed);
      setState(() {
        _jsonText = text;
        _jsonCtrl.text = text;
        _tree = parsed;
        _report = report;
        _pngPath = null;
        _svgPath = null;
        widget.settings.lastDir = File(path).parent.path;
      });
      await widget.settings.save();
      _appendLog('已载入 ${File(path).uri.pathSegments.last}：${parsed.count} 节点，'
          '红牌 ${report.redCount}，软警告 ${report.warnCount}');
    } catch (e) {
      _snack('读取失败：$e');
    }
  }

  Future<void> _openJson() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: '打开编制 JSON',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _loadJsonFile(path);
  }

  Future<void> _generate() async {
    if (_busy) return;
    if (widget.settings.apiKey.trim().isEmpty) {
      _snack('请先在右上角设置里填写 DeepSeek API Key');
      return;
    }
    if (_inputMode == InputMode.textOnly && _textCtrl.text.trim().isEmpty) {
      _snack('纯文本模式：请先粘贴或输入编制资料');
      return;
    }
    if (_inputMode == InputMode.material &&
        _image == null &&
        _textCtrl.text.trim().isEmpty) {
      _snack('请先选择资料图片，或在补充说明里填写内容');
      return;
    }
    if (_inputMode == InputMode.material && _image == null && _textCtrl.text.trim().isEmpty) {
      _snack('请先选择一张编制图，或输入文字资料');
      return;
    }

    AppLogger.instance.section('生成编制');
    AppLogger.instance.info('ui', '生成: image=${_image?.path ?? "无"} '
        'text=${_textCtrl.text.trim().length}字');
    setState(() {
      _busy = true;
      _tree = null;
      _report = null;
      _pngPath = null;
      _svgPath = null;
    });

    final pipeline = OrbatPipeline(
      apiKey: widget.settings.apiKey.trim(),
      model: widget.settings.model,
      renderScriptPath: widget.settings.renderScriptPath,
      whiteBackground: widget.settings.whiteBackground,
    );

    try {
      final useImage = _inputMode == InputMode.material && _image != null;
      final result = useImage
          ? await pipeline.fromImage(
              _image!,
              extraText: _textCtrl.text.trim().isEmpty ? null : _textCtrl.text.trim(),
              onStage: _onStage,
            )
          : await pipeline.fromText(_textCtrl.text.trim(), onStage: _onStage);

      if (result.tree == null) {
        _appendLog('生成失败：${result.error ?? "未知错误"}');
        _snack('生成失败：${result.error ?? "未知错误"}');
        return;
      }

      setState(() {
        _tree = result.tree;
        _report = result.report;
        _jsonText = result.rawJson ?? '';
        _jsonCtrl.text = _jsonText;
      });
      _appendLog('生成完成：${result.tree!.count} 节点，'
          '红牌 ${result.report?.redCount ?? 0}，'
          '修复 ${result.repairRounds} 轮，${result.elapsed.inSeconds}s');
    } catch (e) {
      _appendLog('异常：$e');
      _snack('异常：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _onStage(String stage, String detail) {
    setState(() => _stage = '$stage · $detail');
    _appendLog('$stage: $detail');
  }

  /// 渲染脚本输出里的阶段标记 → (显示名, 进度)
  /// 顺序敏感：先匹配到的生效。进度只增不减，避免心跳行把进度往回拉。
  static const Map<String, (String, double)> _stageMap = {
    '[client] 出图开始': ('准备', 0.02),
    '[client] 使用 node': ('检查运行环境', 0.05),
    '[client] 渲染脚本': ('检查运行环境', 0.06),
    '[stage] 启动浏览器': ('启动浏览器', 0.08),
    '[stage] 浏览器就绪': ('浏览器已就绪', 0.16),
    '[stage] 连接调试通道': ('连接调试通道', 0.22),
    '[stage] 打开渲染站点': ('打开渲染站点', 0.28),
    '[stage] 等待站点初始化': ('等待站点初始化', 0.34),
    '[wait] 站点初始化 就绪': ('站点已就绪', 0.50),
    '[stage] 导入编制数据': ('导入编制数据', 0.54),
    '[wait] 画布渲染 就绪': ('画布渲染完成', 0.68),
    '[stage] 统计渲染结果': ('统计渲染结果', 0.74),
    'SVG_META': ('整理 SVG 结构', 0.82),
    '[stage] 导出 SVG': ('导出 SVG', 0.86),
    'SVG_FILE': ('SVG 已导出', 0.90),
    '[stage] 截图导出 PNG': ('截图导出 PNG', 0.92),
    'PNG_FILE': ('PNG 已导出', 0.98),
    '[stage] 完成': ('完成', 1.0),
  };

  /// 这些是站点渲染器的固有噪音，对判断进度无用，界面上滤掉
  /// （完整日志仍会写进 %APPDATA%\OrbatGenerator\logs\render-*.log）
  static bool _isNoisyLine(String line) {
    final t = line.trimLeft();
    return t.startsWith('[warning]') ||
        t.contains('Unable to load glyph range') ||
        t.startsWith('[pageerror]') ||
        t.startsWith('at ') ||
        t.startsWith('--- browser log ---') ||
        t.contains('临时 profile 没删掉');
  }

  void _onRenderLog(String line) {
    if (!mounted) return;
    setState(() {
      if (!_isNoisyLine(line)) {
        _renderLog.add(line);
        if (_renderLog.length > 300) _renderLog.removeAt(0);
      }

      for (final e in _stageMap.entries) {
        if (line.contains(e.key)) {
          _renderStageName = e.value.$1;
          if (e.value.$2 > _renderProgress) _renderProgress = e.value.$2;
          break;
        }
      }
      // 等待心跳（[wait] xxx 等待中 25s / 120s）不改阶段，但会进日志，用户能看到在动
    });
  }

  Future<void> _render() async {
    if (_busy) return;
    // 文本优先：用户在 JSON 编辑页改过就以改后的为准
    final tree = parseTreeJson(_jsonText) ?? _tree;
    if (tree == null) {
      _snack('还没有可出图的编制数据');
      return;
    }
    if (widget.settings.renderScriptPath.trim().isEmpty) {
      _snack('请在设置里指定渲染脚本 render_orbat.js 的路径');
      return;
    }

    setState(() {
      _busy = true;
      _rendering = true;
      _renderStageName = '准备';
      _renderProgress = 0.01;
      _renderElapsed = Duration.zero;
      _renderLog.clear();
      _lastRenderLogPath = null;
    });

    final watch = Stopwatch()..start();
    _renderTicker?.cancel();
    _renderTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() => _renderElapsed = watch.elapsed);
    });

    final pipeline = OrbatPipeline(
      apiKey: widget.settings.apiKey,
      renderScriptPath: widget.settings.renderScriptPath,
      whiteBackground: widget.settings.whiteBackground,
    );

    try {
      final base = _defaultOutputBase();
      final settings = widget.settings;
      // 产物开关：JSON 单独落盘（编辑页内容为准）
      String? savedJson;
      if (settings.emitJson) {
        final jsonPath = '$base.json';
        await File(jsonPath).writeAsString(_jsonText.isNotEmpty ? _jsonText : normalizeTreeJson(tree));
        savedJson = jsonPath;
        _appendLog('JSON 已保存：$jsonPath');
      }

      // PNG 和 SVG 都不需要 → 跳过渲染，纯 JSON 模式
      if (!settings.emitPng && !settings.emitSvg) {
        _renderTicker?.cancel();
        setState(() {
          _pngPath = null;
          _svgPath = null;
          _renderProgress = 1.0;
          _renderStageName = '完成';
        });
        _appendLog('已按设置仅输出 JSON，跳过渲染');
        return;
      }

      final result = await pipeline.render(
        tree,
        outputBase: base,
        onStage: (s, d) => setState(() => _stage = '$s · $d'),
        onLog: _onRenderLog,
      );

      _renderTicker?.cancel();
      // SVG 不勾选 → 删掉渲染脚本生成的 SVG
      var svgPath = result.svgPath;
      if (result.ok && !settings.emitSvg && svgPath != null) {
        try { await File(svgPath).delete(); } catch (_) {}
        svgPath = null;
      }
      // PNG 不勾选但 SVG 勾选 → 删掉 PNG（纯 SVG 模式）
      var pngPath = result.pngPath;
      if (result.ok && !settings.emitPng && pngPath != null) {
        try { await File(pngPath).delete(); } catch (_) {}
        pngPath = null;
      }

      setState(() {
        _lastRenderLogPath = result.logPath;
        if (result.ok) {
          _pngPath = pngPath;
          _svgPath = svgPath;
          _renderProgress = 1.0;
          _renderStageName = '完成';
        } else {
          _renderStageName = '失败';
        }
      });

      if (result.ok) {
        final saved = <String>[
          if (savedJson != null) 'JSON',
          if (pngPath != null) 'PNG',
          if (svgPath != null) 'SVG',
        ].join(' + ');
        AppLogger.instance.info('ui', '出图完成: $saved @ ${settings.outputDir.isEmpty ? "默认目录" : settings.outputDir} (${result.elapsed.inSeconds}s)');
        _appendLog('出图完成（$saved）：$base（${result.elapsed.inSeconds}s）');
      } else {
        _appendLog('出图失败：${result.error}');
        _snack('出图失败，详见下方日志');
      }
    } catch (e) {
      _renderTicker?.cancel();
      setState(() => _renderStageName = '异常');
      _appendLog('出图异常：$e');
      _snack('出图异常：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  /// 输出基名（不含扩展名）。目录由 [outputDir] 决定：
  /// GUI 默认桌面（用户可通过「更改目录」按钮设置），CLI 默认输入目录。
  String _defaultOutputBase() {
    final dir = outputDir;
    final name = _tree?.uniqueDesignation ?? '编制图';
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    return '$dir/${stamp}_$safe';
  }

  /// GUI 输出目录：优先用户设置，否则桌面
  String get outputDir {
    final d = widget.settings.outputDir.trim();
    if (d.isNotEmpty && Directory(d).existsSync()) return d;
    if (Platform.isWindows) {
      final up = Platform.environment['USERPROFILE'];
      if (up != null && up.isNotEmpty && Directory('$up\\Desktop').existsSync()) {
        return '$up\\Desktop';
      }
    }
    return Platform.environment['HOME'] ?? Directory.systemTemp.path;
  }

  Future<void> _exportJson() async {
    if (_jsonText.trim().isEmpty) {
      _snack('还没有 JSON 可导出');
      return;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出编制 JSON',
      fileName: '${_tree?.uniqueDesignation ?? "编制图"}.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    await File(path).writeAsString(_jsonText);
    _appendLog('JSON 已导出：$path');
    _snack('已导出 JSON');
  }

  Future<void> _exportPng() async {
    final src = _pngPath;
    if (src == null || !File(src).existsSync()) {
      _snack('还没有出图，先点「出图」');
      return;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出 PNG',
      fileName: '${_tree?.uniqueDesignation ?? "编制图"}.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (path == null) return;
    await File(src).copy(path);
    _appendLog('PNG 已导出：$path');
    _snack('已导出 PNG');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openLogDir() async {
    final dir = AppLogger.instance.logDirPath;
    if (dir == null) {
      _snack('日志未启用（目录不可写）');
      return;
    }
    try {
      await Process.run('explorer', [dir]);
    } catch (e) {
      _snack('打开失败：$e');
    }
  }

  Future<void> _exportLog() async {
    final src = AppLogger.instance.currentLogPath;
    if (src == null || !File(src).existsSync()) {
      _snack('当前还没有日志文件');
      return;
    }
    try {
      final out = await FilePicker.platform.saveFile(
        dialogTitle: '导出本次日志',
        fileName: 'orbat-log-${DateTime.now().millisecondsSinceEpoch}.log',
        type: FileType.custom,
        allowedExtensions: ['log', 'txt'],
      );
      if (out == null) return;
      await File(src).copy(out);
      AppLogger.instance.info('ui', '日志已导出: $out');
      _snack('已导出到 $out');
    } catch (e) {
      _snack('导出失败：$e');
    }
  }

  Future<void> _copyDiagnostics() async {
    final tree = _tree;
    final buf = StringBuffer()
      ..writeln('版本: $kAppVersion')
      ..writeln('时间: ${DateTime.now()}')
      ..writeln('日志文件: ${AppLogger.instance.currentLogPath ?? "未启用"}')
      ..writeln('快照目录: ${AppLogger.instance.snapshotDirPath ?? "-"}')
      ..writeln('模型: ${widget.settings.model}')
      ..writeln('API Key: ${AppLogger.keyFingerprint(widget.settings.apiKey)}')
      ..writeln('当前树: ${tree == null ? "无" : "${tree.count} 节点 / 层级 ${tree.maxDepth}"}')
      ..writeln('最近出图: ${_pngPath ?? "无"}')
      ..writeln('最近SVG: ${_svgPath ?? "无"}');
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    _snack('诊断信息已复制到剪贴板');
  }

  /// JSON 编辑页是否有未应用的改动
  bool get _jsonDirty {
    final tree = _tree;
    if (tree == null) return false;
    final cur = _jsonText.trim();
    if (cur.isEmpty) return false;
    return cur != normalizeTreeJson(tree).trim();
  }

  /// 重置到初始状态：清空当前图片、编制树、出图结果和日志面板。
  ///
  /// 说明：曾尝试做「一键重启进程」，但不可行——Flutter 应用加载
  /// `flutter_windows.dll` 和 `data/` 时依赖**工作目录**，而 detached 启动的子进程
  /// 拿不到正确的 cwd（Windows 的 DLL 搜索顺序包含当前目录），
  /// 会在 Dart 代码执行之前就崩溃，因此无法在进程内自行修复。
  /// 换新版本时请关闭窗口后重新双击「启动.exe」。
  Future<void> _resetApp() async {
    if (_busy) return;

    if (_jsonDirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('有未保存的修改'),
          content: const Text('JSON 编辑页的内容还没点「应用」，重置后会丢失。\n继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续重置'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    AppLogger.instance.info('ui', '用户重置到初始状态');
    setState(() {
      _tree = null;
      _report = null;
      _image = null;
      _jsonText = '';
      _jsonCtrl.clear();
      _pngPath = null;
      _log.clear();
      _stage = '就绪';
    });
    _appendLog('已重置到初始状态（换新版本请关闭窗口后重新打开）');
  }

  /// 查看最近一次 API 对话：完整 prompt + 模型输出（观察/JSON/自检）+ 思考链 + 用量
  Future<void> _showConversation() async {
    final conv = DeepSeekClient.lastConversation;
    if (conv == null || conv.isEmpty) {
      _snack('还没有 API 调用记录，先生成一次编制');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final content = (conv['content'] ?? '').toString();
        final reasoning = (conv['reasoning'] ?? '').toString();

        // 从三段式输出里拆出 <观察> / <json> / <自检>
        String section(String tag) {
          final m = RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(content);
          return m?.group(1)?.trim() ?? '';
        }

        final observation = section('观察');
        final jsonPart = section('json');
        final selfCheck = section('自检');
        final hasSections = observation.isNotEmpty || jsonPart.isNotEmpty;

        final inTok = conv['inTok'] ?? 0;
        final outTok = conv['outTok'] ?? 0;
        final ms = conv['ms'] ?? 0;

        Widget codeBlock(String text) => Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              child: SelectableText(
                text.isEmpty ? '（空）' : text,
                style: const TextStyle(
                    fontSize: 12, fontFamily: 'Consolas', height: 1.4),
              ),
            );

        Widget label(String text) => Padding(
              padding: const EdgeInsets.only(bottom: 6, top: 2),
              child: Text(text, style: theme.textTheme.titleSmall),
            );

        return Dialog(
          child: SizedBox(
            width: 780,
            height: 620,
            child: Column(
              children: [
                // 标题栏：模型 + token + 耗时
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('最近一次 API 对话',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(width: 12),
                      Text(
                        '${conv['model']} · 入 $inTok / 出 $outTok token · '
                        '${(ms / 1000).toStringAsFixed(1)}s · ${conv['finish']}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '复制完整响应',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: content));
                          _snack('已复制完整响应');
                        },
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: DefaultTabController(
                    // tab 数必须与下面 TabBar 的 tabs 一致：
                    // 三段(观察/json/自检) + 完整响应 + Prompt + 可选思考链
                    length: (hasSections ? 3 : 0) +
                        2 +
                        (reasoning.isNotEmpty ? 1 : 0),
                    child: Column(
                      children: [
                        TabBar(
                          tabs: [
                            if (hasSections) ...[
                              const Tab(text: '观察(思考)'),
                              const Tab(text: 'JSON'),
                              const Tab(text: '自检'),
                            ],
                            const Tab(text: '完整响应'),
                            if (reasoning.isNotEmpty) const Tab(text: '思考链'),
                            const Tab(text: 'Prompt'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              if (hasSections) ...[
                                SingleChildScrollView(
                                    padding: const EdgeInsets.all(14),
                                    child: codeBlock(observation)),
                                SingleChildScrollView(
                                    padding: const EdgeInsets.all(14),
                                    child: codeBlock(jsonPart)),
                                SingleChildScrollView(
                                    padding: const EdgeInsets.all(14),
                                    child: codeBlock(selfCheck)),
                              ],
                              SingleChildScrollView(
                                padding: const EdgeInsets.all(14),
                                child: codeBlock(content),
                              ),
                              if (reasoning.isNotEmpty)
                                SingleChildScrollView(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('模型原生思考链（reasoning_content）：'
                                          '仅 deepseek-reasoner 等模型会产生；'
                                          'deepseek-flash 默认关闭，此栏通常为空。',
                                          style: TextStyle(fontSize: 11)),
                                      const SizedBox(height: 8),
                                      codeBlock(reasoning),
                                    ],
                                  ),
                                ),
                              SingleChildScrollView(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    label('System Prompt'),
                                    codeBlock((conv['system'] ?? '').toString()),
                                    const SizedBox(height: 12),
                                    label('User Prompt'),
                                    codeBlock((conv['user'] ?? '').toString()),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// API 用量面板
  Future<void> _showUsage() async {
    final summary = await UsageStore.summary();
    final recent = await UsageStore.recent(limit: 20);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        Widget row(String k, String v, {Color? color}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(width: 110, child: Text(k, style: theme.textTheme.bodySmall)),
                  Text(v,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            );

        return AlertDialog(
          title: const Text('API 用量'),
          content: SizedBox(
            width: 560,
            height: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('今日', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                row('调用次数', '${summary.todayCalls} 次'),
                row('输入 token', _fmt(summary.todayIn)),
                row('输出 token', _fmt(summary.todayOut)),
                row('合计 token', _fmt(summary.todayTokens),
                    color: theme.colorScheme.primary),
                const Divider(height: 20),
                Text('本月', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                row('调用次数', '${summary.monthCalls} 次'),
                row('合计 token', _fmt(summary.monthTokens),
                    color: theme.colorScheme.primary),
                const Divider(height: 20),
                Text('最近 ${recent.length} 次调用', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Expanded(
                  child: recent.isEmpty
                      ? Center(
                          child: Text('还没有调用记录',
                              style: TextStyle(color: theme.hintColor)),
                        )
                      : ListView.builder(
                          itemCount: recent.length,
                          itemBuilder: (_, i) {
                            final e = recent[i];
                            final t = e.time;
                            final ts = '${t.month.toString().padLeft(2, '0')}-'
                                '${t.day.toString().padLeft(2, '0')} '
                                '${t.hour.toString().padLeft(2, '0')}:'
                                '${t.minute.toString().padLeft(2, '0')}';
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  SizedBox(
                                      width: 88,
                                      child: Text(ts,
                                          style: const TextStyle(fontSize: 11))),
                                  SizedBox(
                                      width: 72,
                                      child: Text(e.scene,
                                          style: const TextStyle(fontSize: 11))),
                                  Expanded(
                                    child: Text(
                                      'in ${_fmt(e.promptTokens)} / out ${_fmt(e.completionTokens)}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  Text('${(e.ms / 1000).toStringAsFixed(1)}s',
                                      style: const TextStyle(fontSize: 11)),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (c2) => AlertDialog(
                    title: const Text('清空统计？'),
                    content: const Text('会删除本机保存的全部用量记录，不可恢复。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c2, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(c2, true),
                          child: const Text('清空')),
                    ],
                  ),
                );
                if (ok == true) {
                  await UsageStore.clear();
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: const Text('清空统计'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }

  /// 一键环境自检
  Future<void> _runSelfCheck() async {
    setState(() => _stage = '自检中…');
    SelfCheckResult result;
    try {
      result = await SelfCheck.run(
        renderScriptPath: widget.settings.renderScriptPath,
        apiKey: widget.settings.apiKey,
      );
    } catch (e) {
      _snack('自检失败：$e');
      setState(() => _stage = '就绪');
      return;
    }
    setState(() => _stage = '就绪');
    if (!mounted) return;

    _appendLog('自检完成：失败 ${result.failCount} 项，警告 ${result.warnCount} 项');

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                result.allOk ? Icons.check_circle : Icons.error_outline,
                color: result.allOk ? Colors.green : Colors.orange,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(result.allOk ? '环境正常' : '发现 ${result.failCount} 项问题'),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: 420,
            child: ListView(
              children: result.items.map((i) {
                final color = i.ok
                    ? Colors.green
                    : (i.optional ? Colors.orange : Colors.red);
                final icon = i.ok
                    ? Icons.check
                    : (i.optional ? Icons.warning_amber : Icons.close);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(i.name,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 1),
                            Text(i.detail,
                                style: TextStyle(
                                    fontSize: 11, color: theme.hintColor)),
                            if (i.fix != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text('→ ${i.fix}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: theme.colorScheme.primary)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSettings() async {
    final keyCtrl = TextEditingController(text: widget.settings.apiKey);
    final scriptCtrl = TextEditingController(text: widget.settings.renderScriptPath);
    final modelCtrl = TextEditingController(text: widget.settings.model);
    int modeVal = widget.settings.mode;
    const modeNames = ['模式一 · 纯软件', '模式二 · 软件+CLI(配API)', '模式三 · Agent插件(无需API)'];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
        title: const Text('设置'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: modeVal,
                decoration: const InputDecoration(
                  labelText: '工作模式',
                  helperText: '模式一：GUI 手动使用｜模式二：CLI 交给 Agent，软件配 API｜模式三：Agent 全权，软件不配 API',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (var i = 0; i < modeNames.length; i++)
                    DropdownMenuItem(value: i, child: Text(modeNames[i])),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setDlgState(() => modeVal = v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                // 模式三（Agent 全权）不需要软件 API：灰化且禁止编辑
                enabled: modeVal != 2,
                decoration: InputDecoration(
                  labelText: 'DeepSeek API Key',
                  hintText: 'sk-...',
                  helperText: modeVal == 2
                      ? '模式三由 AI Agent 调用自己的 API，本软件不需要 Key'
                      : '仅存于本机配置文件（混淆存储）',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: SettingsStore.knownModels.containsKey(modelCtrl.text)
                    ? modelCtrl.text
                    : null,
                // 模式三灰化：模型由 Agent 决定，软件不调 API
                disabledHint: const Text('模式三由 Agent 决定模型'),
                decoration: InputDecoration(
                  labelText: '识图模型',
                  helperText: modeVal == 2
                      ? '模式三不使用本软件的识图模型'
                      : '任选预设，也可在下方手填自定义模型 id',
                  border: const OutlineInputBorder(),
                ),
                items: [
                  ...SettingsStore.knownModels.entries.map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ),
                  const DropdownMenuItem(value: '__custom__', child: Text('自定义…')),
                ],
                onChanged: modeVal == 2 ? null : (v) {
                  if (v == null) return;
                  if (v == '__custom__') {
                    modelCtrl.clear();
                  } else {
                    modelCtrl.text = v;
                  }
                  setDlgState(() {});
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: modelCtrl,
                enabled: modeVal != 2,
                decoration: InputDecoration(
                  labelText: '模型 id（可手填）',
                  hintText: 'deepseek-flash',
                  helperText: modeVal == 2 ? '模式三不使用本软件的识图模型' : null,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: scriptCtrl,
                decoration: const InputDecoration(
                  labelText: '渲染脚本 render_orbat.js',
                  helperText: '出图用的线上渲染脚本绝对路径',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '说明：出图必须联网，调用 spatialillusions.com 线上渲染器。\n'
                '需要 node ≥ 24，脚本会自行探测。',
                style: TextStyle(fontSize: 12),
              ),
              const Divider(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('日志与诊断',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    )),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  AppLogger.instance.logDirPath ?? '（日志未启用：目录不可写）',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: _openLogDir,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('打开日志目录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _exportLog,
                    icon: const Icon(Icons.save_alt, size: 16),
                    label: const Text('导出本次日志'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _copyDiagnostics,
                    icon: const Icon(Icons.copy_all, size: 16),
                    label: const Text('复制诊断信息'),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              widget.settings.apiKey = keyCtrl.text.trim();
              widget.settings.renderScriptPath = scriptCtrl.text.trim();
              widget.settings.model = modelCtrl.text.trim().isEmpty
                  ? 'deepseek-flash'
                  : modelCtrl.text.trim();
              widget.settings.mode = modeVal;
              await widget.settings.save();
              if (ctx.mounted) Navigator.pop(ctx);
              _appendLog('设置已保存');
            },
            child: const Text('保存'),
          ),
        ],
      ),
      ),
    );
    keyCtrl.dispose();
    scriptCtrl.dispose();
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.account_tree_outlined, size: 22),
            const SizedBox(width: 10),
            const Text('编制图生成器', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 12),
            if (_busy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : _pickImage,
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('选择图片'),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('生成编制'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: _busy ? null : _render,
            icon: const Icon(Icons.photo_outlined, size: 18),
            label: const Text('出图'),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: '打开已有编制 JSON',
            onPressed: _busy ? null : _openJson,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: 'API 用量（调用次数 / token 消耗）',
            onPressed: _showUsage,
            icon: const Icon(Icons.data_usage_outlined),
          ),
          IconButton(
            tooltip: '查看 API 对话（观察/思考过程、JSON、自检、Prompt）',
            onPressed: _showConversation,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: '环境自检（检查依赖与工具是否齐全）',
            onPressed: _busy ? null : _runSelfCheck,
            icon: const Icon(Icons.health_and_safety_outlined),
          ),
          IconButton(
            tooltip: '切换主题',
            onPressed: widget.onToggleTheme,
            icon: const Icon(Icons.brightness_6_outlined),
          ),
          IconButton(
            tooltip: '重置（清空当前内容，回到初始状态）',
            onPressed: _busy ? null : _resetApp,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 320, child: _buildInputPane(theme)),
          const VerticalDivider(width: 1),
          Expanded(flex: 5, child: _buildTreePane(theme)),
          const VerticalDivider(width: 1),
          Expanded(flex: 4, child: _buildPreviewPane(theme)),
        ],
      ),
      bottomNavigationBar: _buildStatusBar(theme),
    );
  }

  Widget _buildInputPane(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<InputMode>(
            segments: const [
              ButtonSegment(
                value: InputMode.material,
                icon: Icon(Icons.perm_media_outlined, size: 16),
                label: Text('资料为主'),
              ),
              ButtonSegment(
                value: InputMode.textOnly,
                icon: Icon(Icons.text_fields, size: 16),
                label: Text('纯文本'),
              ),
            ],
            selected: {_inputMode},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: _busy
                ? null
                : (v) => setState(() => _inputMode = v.first),
          ),
          const SizedBox(height: 10),
          if (_inputMode == InputMode.material) ...[
          // 图片区
          InkWell(
            onTap: _busy ? null : _pickImage,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.dividerColor),
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              ),
              clipBehavior: Clip.antiAlias,
              child: _image == null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              size: 34, color: theme.hintColor),
                          const SizedBox(height: 8),
                          Text('点击选择编制图', style: TextStyle(color: theme.hintColor)),
                          const SizedBox(height: 4),
                          Text('PNG / JPG',
                              style: TextStyle(fontSize: 11, color: theme.hintColor)),
                        ],
                      ),
                    )
                  : Image.file(_image!, fit: BoxFit.contain),
            ),
          ),
          if (_image != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _image!.path.split(RegExp(r'[\\/]')).last,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '移除',
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy
                        ? null
                        : () => setState(() => _image = null),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                  _inputMode == InputMode.material ? '补充说明（可选）' : '编制资料（纯文本）',
                  style: theme.textTheme.bodySmall),
              if (_inputMode == InputMode.textOnly) ...[
                const SizedBox(width: 6),
                Text('（直接粘贴或手打单位清单）',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor, fontSize: 11)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: _inputMode == InputMode.material ? 1 : 3,
            child: TextField(
              controller: _textCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                hintText: _inputMode == InputMode.material
                    ? '可补充：编制年代、番号体系、需要保留的原文缩写等。\n'
                        '大图也可以给结构提示：\n'
                        '总根：第1近卫机械化师\n'
                        '下辖：师部、第453机械化旅、第51机械化旅'
                    : '粘贴文字资料，例如：\n'
                        '第1步兵团（空中机动战斗团）\n'
                        '- 指挥与勤务连\n'
                        '  - 情报科\n'
                        '  - 通信排\n'
                        '- 轻型侦察连\n'
                        '……\n\n'
                        '每行一个单位，用缩进表示层级即可。',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (_inputMode == InputMode.material) ...[
            const SizedBox(height: 10),
            Text(
              '提示：模型偏好中文单位名；外文资料可在补充说明里要求保留原始缩写。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTreePane(ThemeData theme) {
    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 200,
                  child: TabBar(
                    labelStyle: TextStyle(fontSize: 13),
                    tabs: [
                      Tab(height: 38, text: '结构'),
                      Tab(height: 38, text: 'JSON 编辑'),
                      Tab(height: 38, text: '批量'),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_report != null) _reportChip(theme, _report!),
                const Spacer(),
                TextButton.icon(
                  onPressed: _jsonText.isEmpty ? null : _validateEditedJson,
                  icon: const Icon(Icons.rule_outlined, size: 16),
                  label: const Text('校验'),
                ),
                TextButton.icon(
                  onPressed: _jsonText.isEmpty ? null : _exportJson,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('导出'),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                (_tree == null && _jsonText.isEmpty)
                    ? _emptyHint(theme, '生成后会在这里显示编制结构\n每个节点都会标注 SIDC 解读结果')
                    : _buildStructureTab(theme),
                _buildJsonEditor(theme),
                _buildBatchTab(theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 批量处理 ====================

  /// 选择多张图片加入批量队列
  Future<void> _pickBatchImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
      allowMultiple: true,
      dialogTitle: '选择多张编制图（可多选）',
    );
    if (result == null || result.files.isEmpty) return;

    final queue = _batchQueue ??= BatchQueue(
      runner: _runBatchTask,
      onUpdate: (task, i, total) {
        if (mounted) setState(() {});
      },
    );

    final added = <BatchTask>[];
    for (final f in result.files) {
      if (f.path == null) continue;
      final name = f.name;
      added.add(BatchTask(
        id: '${DateTime.now().microsecondsSinceEpoch}_${added.length}',
        sourcePath: f.path!,
        displayName: name,
        extraText: _textCtrl.text.trim().isEmpty ? null : _textCtrl.text.trim(),
      ));
    }
    queue.addAll(added);
    if (added.isNotEmpty) {
      widget.settings.lastDir = File(added.first.sourcePath).parent.path;
      await widget.settings.save();
    }
    AppLogger.instance.info('batch', '已加入 ${added.length} 个任务');
  }

  /// 单个批量任务的执行器：复用 OrbatPipeline 的 generate + render
  Future<BatchTaskResult> _runBatchTask(
    BatchTask task,
    void Function(String stage) onStage,
  ) async {
    final settings = widget.settings;
    final pipeline = OrbatPipeline(
      apiKey: settings.apiKey.trim(),
      model: settings.model,
      renderScriptPath: settings.renderScriptPath,
      whiteBackground: settings.whiteBackground,
    );

    final img = File(task.sourcePath);
    if (!img.existsSync()) {
      return BatchTaskResult(ok: false, error: '文件不存在: ${task.sourcePath}');
    }

    // 输出目录 = 图片所在目录
    final outDir = img.parent.path;
    final baseName = _safeBaseName(task.displayName);
    final outputBase = '$outDir${Platform.pathSeparator}$baseName';

    onStage('generate');
    final gen = await pipeline.fromImage(
      img,
      extraText: task.extraText,
      onStage: (s, d) => AppLogger.instance.debug('batch', '$s: $d'),
    );
    if (gen.tree == null) {
      return BatchTaskResult(
        ok: false,
        error: gen.error ?? '识图失败',
        outputBase: outputBase,
      );
    }

    final jsonPath = '$outputBase.json';
    await File(jsonPath).writeAsString(gen.rawJson ?? normalizeTreeJson(gen.tree!));

    onStage('render');
    final r = await pipeline.render(
      gen.tree!,
      outputBase: outputBase,
      onStage: (s, d) => AppLogger.instance.debug('batch', '$s: $d'),
    );

    return BatchTaskResult(
      ok: r.ok,
      nodeCount: gen.tree!.count,
      outputBase: outputBase,
      pngPath: r.pngPath,
      svgPath: r.svgPath,
      jsonPath: jsonPath,
      error: r.error,
    );
  }

  String _safeBaseName(String fileName) {
    var s = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final now = DateTime.now();
    final d = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    return '${d}_$s';
  }

  Future<void> _startBatch() async {
    final queue = _batchQueue;
    if (queue == null || queue.tasks.isEmpty) {
      _snack('请先添加图片');
      return;
    }
    if (queue.isRunning) return;
    setState(() => _batchBusy = true);
    try {
      await queue.run();
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
    if (mounted) {
      final s = queue;
      _snack('批量完成：成功 ${s.doneCount}，失败 ${s.failedCount}');
    }
  }

  Future<void> _retryBatchTask(String id) async {
    final queue = _batchQueue;
    if (queue == null || queue.isRunning) return;
    setState(() => _batchBusy = true);
    try {
      await queue.retry(id);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  /// 用某次批量结果替换当前树，并保存上一版供对比
  void _loadBatchResult(BatchTask task) {
    if (task.jsonPath == null || !File(task.jsonPath!).existsSync()) return;
    final parsed = parseTreeJson(File(task.jsonPath!).readAsStringSync());
    if (parsed == null) {
      _snack('无法读取该结果');
      return;
    }
    setState(() {
      _previousTree = _tree;
      _tree = parsed;
      _report = OrbatValidator.validate(parsed);
      _jsonText = normalizeTreeJson(parsed);
      _jsonCtrl.text = _jsonText;
      _pngPath = task.pngPath;
      _svgPath = task.svgPath;
      _lastDiff = TreeDiffer.compare(_previousTree, parsed);
    });
    _snack('已载入结果，切到「结构」查看');
  }

  /// 显示最近一次载入的差异
  Future<void> _showDiff() async {
    final diff = _lastDiff;
    if (diff == null) {
      _snack('还没有可对比的结果（先从批量列表载入一个）');
      return;
    }
    if (diff.isEmpty) {
      _snack('两次结果没有差异');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final colors = {
          DiffKind.added: Colors.green,
          DiffKind.removed: Colors.red,
          DiffKind.renamed: Colors.orange,
          DiffKind.sidcChanged: Colors.purple,
          DiffKind.noteChanged: Colors.teal,
          DiffKind.moved: Colors.blue,
        };
        return AlertDialog(
          title: Text('结果对比（${diff.items.length} 处差异）'),
          content: SizedBox(
            width: 620,
            height: 420,
            child: ListView.builder(
              itemCount: diff.items.length,
              itemBuilder: (_, i) {
                final it = diff.items[i];
                return ListTile(
                  dense: true,
                  leading: Icon(Icons.circle, size: 10, color: colors[it.kind]),
                  title: Text('${it.label}: ${it.name}',
                      style: const TextStyle(fontSize: 12)),
                  subtitle: Text(
                    it.oldValue != null && it.newValue != null
                        ? '${it.oldValue} → ${it.newValue}'
                        : it.path,
                    style: TextStyle(fontSize: 11, color: theme.hintColor),
                  ),
                );
              },
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBatchTab(ThemeData theme) {
    final queue = _batchQueue;
    final tasks = queue?.tasks ?? const <BatchTask>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _batchBusy ? null : _pickBatchImages,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: const Text('添加图片'),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: (_batchBusy || tasks.isEmpty)
                    ? null
                    : _startBatch,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(_batchBusy ? '处理中…' : '开始批量'),
              ),
              if (_batchBusy)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: TextButton(
                    onPressed: () => setState(() => queue?.cancel()),
                    child: const Text('取消'),
                  ),
                ),
              const Spacer(),
              if (queue != null && tasks.isNotEmpty)
                Text('${queue.doneCount}/${tasks.length} 完成 · 失败 ${queue.failedCount}',
                    style: theme.textTheme.bodySmall),
              if (_lastDiff != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _showDiff,
                  icon: const Icon(Icons.compare_arrows, size: 16),
                  label: const Text('对比'),
                ),
              ],
              if (tasks.isNotEmpty)
                IconButton(
                  tooltip: '清空列表',
                  onPressed: _batchBusy
                      ? null
                      : () => setState(() {
                          queue?.clear();
                          _lastDiff = null;
                        }),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                ),
            ],
          ),
        ),
        if (tasks.isEmpty)
          Expanded(
            child: _emptyHint(
              theme,
              '批量识图 + 自动出图\n\n'
              '点「添加图片」一次选多张，程序会串行处理：\n'
              '· 每张自动生成 JSON + PNG + SVG，存到图片同目录\n'
              '· 失败的可单独重试，不影响其他任务\n'
              '· 点击已完成的结果可载入到左侧，再点「对比」看差异',
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (_, i) {
                final t = tasks[i];
                final color = switch (t.status) {
                  BatchStatus.done => Colors.green,
                  BatchStatus.failed => Colors.red,
                  BatchStatus.running ||
                  BatchStatus.generating ||
                  BatchStatus.rendering => Colors.blue,
                  BatchStatus.skipped => Colors.grey,
                  BatchStatus.pending => theme.hintColor,
                };
                final statusText = switch (t.status) {
                  BatchStatus.pending => '等待',
                  BatchStatus.running => t.stage.isEmpty ? '准备' : t.stage,
                  BatchStatus.generating => '识图中',
                  BatchStatus.rendering => '出图中',
                  BatchStatus.done => '完成 · ${t.nodeCount ?? 0} 节点',
                  BatchStatus.failed => '失败',
                  BatchStatus.skipped => '跳过',
                };
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 10,
                      backgroundColor: color.withValues(alpha: 0.2),
                      child: Icon(
                        t.status == BatchStatus.done
                            ? Icons.check
                            : t.status == BatchStatus.failed
                                ? Icons.close
                                : Icons.schedule,
                        size: 12,
                        color: color,
                      ),
                    ),
                    title: Text(t.displayName,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      t.error ??
                          '$statusText · ${(t.elapsedMs / 1000).toStringAsFixed(1)}s'
                              '${t.attempts > 1 ? " · 第${t.attempts}次" : ""}',
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (t.status == BatchStatus.failed)
                          IconButton(
                            tooltip: '重试这一张',
                            onPressed: _batchBusy
                                ? null
                                : () => _retryBatchTask(t.id),
                            icon: const Icon(Icons.replay, size: 18),
                          ),
                        if (t.status == BatchStatus.done && t.jsonPath != null)
                          IconButton(
                            tooltip: '载入这个结果',
                            onPressed: () => _loadBatchResult(t),
                            icon: const Icon(Icons.open_in_new, size: 18),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildStructureTab(ThemeData theme) {
    if (_tree != null) {
      return TreeView(root: _tree!, report: _report, focusPath: _focusPath);
    }
    // 手改 JSON 后没有树对象时，尝试从文本解析出一棵临时树
    final parsed = parseTreeJson(_jsonText);
    if (parsed == null) {
      return _emptyHint(theme, 'JSON 无法解析为编制树\n请切到「JSON 编辑」检查语法');
    }
    return TreeView(
        root: parsed,
        report: OrbatValidator.validate(parsed),
        focusPath: _focusPath,
      );
  }

  Widget _buildJsonEditor(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: TextField(
        controller: _jsonCtrl,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.all(10),
          hintText: '生成的 JSON 会出现在这里，可直接修改后点「校验」或「出图」',
          helperText: '修改后会以文本为准出图；点「校验」可检查红牌问题',
          helperStyle: TextStyle(fontSize: 11, color: theme.hintColor),
        ),
        onChanged: (v) => _jsonText = v,
      ),
    );
  }

  /// 校验结果 chip：点击展开问题列表，点某条可跳到树节点并高亮
  Widget _reportChip(ThemeData theme, ValidationReport report) {
    final ok = report.ok;
    final color = ok ? Colors.green : Colors.red;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _showValidationIssues(report),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              '${report.nodeCount} 节点 · 红牌 ${report.redCount} · 警告 ${report.warnCount}',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showValidationIssues(ValidationReport report) async {
    if (report.issues.isEmpty) {
      _snack('没有校验问题');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text('校验问题（${report.issues.length}）'),
          content: SizedBox(
            width: 620,
            height: 420,
            child: ListView.builder(
              itemCount: report.issues.length,
              itemBuilder: (_, i) {
                final issue = report.issues[i];
                final red = issue.level == 'red';
                final c = red ? Colors.red : Colors.orange;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    red ? Icons.error_outline : Icons.warning_amber_outlined,
                    size: 18,
                    color: c,
                  ),
                  title: Text(
                    issue.message,
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    issue.path,
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: theme.hintColor,
                    ),
                  ),
                  onTap: () {
                    setState(() => _focusPath = issue.path);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
          actions: [
            if (_focusPath != null)
              TextButton(
                onPressed: () {
                  setState(() => _focusPath = null);
                  Navigator.pop(ctx);
                },
                child: const Text('清除高亮'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  bool get _showProgressPanel =>
      _rendering || _renderStageName == '失败' || _renderStageName == '异常';

  /// 产物勾选 chip
  Widget _outputChip(String label, bool value, Future<void> Function(bool) onChanged) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: value,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: _busy ? null : onChanged,
    );
  }

  /// 更改输出目录（GUI 用；CLI 用输入目录）
  Future<void> _pickOutputDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择输出目录（JSON / PNG / SVG 保存位置）',
      initialDirectory: outputDir,
    );
    if (result == null || result.isEmpty) return;
    setState(() => widget.settings.outputDir = result);
    await widget.settings.save();
    AppLogger.instance.info('ui', '输出目录已改为: $result');
    _snack('输出目录：$result');
  }

  Widget _buildPreviewPane(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              Text('出图成品', style: theme.textTheme.titleSmall),
              const Spacer(),
              // 产物勾选：决定出图时输出哪些文件
              _outputChip('JSON', widget.settings.emitJson, (v) async {
                setState(() => widget.settings.emitJson = v);
                await widget.settings.save();
              }),
              const SizedBox(width: 2),
              _outputChip('PNG', widget.settings.emitPng, (v) async {
                setState(() => widget.settings.emitPng = v);
                await widget.settings.save();
              }),
              const SizedBox(width: 2),
              _outputChip('SVG', widget.settings.emitSvg, (v) async {
                setState(() => widget.settings.emitSvg = v);
                await widget.settings.save();
              }),
              const SizedBox(width: 8),
              // 白色背景开关
              Tooltip(
                message: '开=白底 PNG；关=透明底（可叠自定义背景图）',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('白底',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: widget.settings.whiteBackground
                                ? null
                                : theme.hintColor)),
                    Switch(
                      value: widget.settings.whiteBackground,
                      onChanged: _busy
                          ? null
                          : (v) async {
                              setState(() => widget.settings.whiteBackground = v);
                              await widget.settings.save();
                              AppLogger.instance.info(
                                  'ui', 'PNG 白底开关: ${v ? "开" : "关"}');
                            },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: _exportPng,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('导出 PNG'),
              ),
            ],
          ),
        ),
        // 第二行：当前输出目录 + 更改按钮（让 AI Agent 和用户明确产物位置）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 13, color: theme.hintColor),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '输出目录：${outputDir}',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _pickOutputDir,
                child: const Text('更改目录', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        if (_showProgressPanel) _buildRenderProgress(theme),
        Expanded(
          child: _pngPath == null
              ? _emptyHint(
                  theme,
                  _rendering
                      ? '正在出图…\n进度见上方，完整日志在下方'
                      : '点顶部「出图」调用线上渲染器\n需要联网，约 15-60 秒',
                )
              : InteractiveViewer(
                  maxScale: 5,
                  minScale: 0.2,
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(8),
                    child: Image.file(
                      File(_pngPath!),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
        ),
        _buildLogPanel(theme),
      ],
    );
  }

  /// 出图进度面板：阶段名 + 百分比 + 耗时 + 实时输出
  Widget _buildRenderProgress(ThemeData theme) {
    final failed = _renderStageName == '失败' || _renderStageName == '异常';
    final color = failed ? Colors.red : theme.colorScheme.primary;
    final pct = (_renderProgress * 100).clamp(0, 100).toStringAsFixed(0);
    final secs = _renderElapsed.inMilliseconds / 1000;

    // 实时输出只取最后几行有信息量的
    final recent = _renderLog
        .where((l) =>
            !l.startsWith('[warning]') &&
            !l.contains('Unable to load glyph range') &&
            !l.startsWith('[pageerror]'))
        .toList();
    final tail = recent.length <= 6 ? recent : recent.sublist(recent.length - 6);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.sync,
                size: 15,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _renderStageName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: failed ? Colors.redAccent : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${secs.toStringAsFixed(1)}s',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.hintColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (_lastRenderLogPath != null)
                IconButton(
                  tooltip: '打开完整日志',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                  onPressed: () {
                    _appendLog('完整日志：$_lastRenderLogPath');
                    _snack('完整日志：$_lastRenderLogPath');
                  },
                  icon: const Icon(Icons.description_outlined, size: 15),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _renderProgress <= 0 ? null : _renderProgress.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: theme.dividerColor,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (tail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in tail)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: Text(
                        _shorten(l),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'Consolas',
                          color: theme.hintColor,
                          height: 1.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _shorten(String s, {int max = 110}) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  Widget _buildLogPanel(ThemeData theme) {
    return Container(
      height: 130,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
            child: Row(
              children: [
                Text('运行日志', style: theme.textTheme.bodySmall),
                const Spacer(),
                IconButton(
                  tooltip: '复制日志',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _log.join('\n')));
                    _snack('日志已复制');
                  },
                  icon: const Icon(Icons.copy_all_outlined, size: 15),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  _log[i],
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    color: theme.hintColor,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ThemeData theme) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      ),
      child: Row(
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          Expanded(
            child: Text(
              _stage,
              style: TextStyle(fontSize: 11, color: theme.hintColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '模型 ${widget.settings.model}',
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(ThemeData theme, String text) {
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: theme.hintColor, height: 1.6),
      ),
    );
  }
}
