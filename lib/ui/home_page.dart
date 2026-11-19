import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/l10n.dart';
import 'l10n_ui.dart';
import 'tutorial_dialog.dart';
import '../core/app_paths.dart';
import '../core/auto_fix.dart';
import '../core/patch_repair.dart';
import '../core/schema_rules.dart';
import '../core/orbat.dart';
import '../core/version.dart';
import '../core/logger.dart';
import '../core/batch_queue.dart';
import '../core/tree_diff.dart';
import '../core/usage_store.dart';
import '../core/self_check.dart';
import '../pipeline.dart';
import '../ai/deepseek_client.dart';
import '../render/renderer.dart';
import '../services/plugin_bridge.dart';
import '../services/settings_store.dart';
import 'render_webview_page.dart';
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

  /// 窄屏（手机）当前分页：0=资料 1=编制树 2=预览
  int _mobilePane = 0;

  /// 对话框宽度：桌面用固定宽，手机（屏宽不足时）收窄到屏宽-48，
  /// 否则 AlertDialog 内容会报 RIGHT OVERFLOWED BY xx PIXELS
  double _dialogW(double desktop) {
    final sw = MediaQuery.of(context).size.width;
    return sw - 48 < desktop ? sw - 48 : desktop;
  }
  String _stage = tr('就绪');
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
      _snack(tr('JSON 解析失败，请检查语法（括号、逗号、引号）'));
      _appendLog('JSON 解析失败');
      return;
    }
    final report = OrbatValidator.validate(parsed);
    setState(() {
      _tree = parsed;
      _report = report;
    });
    _appendLog(
        '手工 JSON 校验：${parsed.count} 节点，红牌 ${report.redCount}，软警告 ${report.warnCount}');
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
      allowedExtensions: const [
        'png',
        'jpg',
        'jpeg',
        'webp',
        'bmp',
        'pdf',
        'doc',
        'docx'
      ],
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
          title: Text(tr('PDF / DOC 会显著增加消耗')),
          content: Text(
            tr('把一个 PDF 交给视觉模型，需要逐页转成图片，'
                'token 消耗通常是单张图片的 3-10 倍，页数多的文件尤其明显。\n\n'
                '更省的做法：\n'
                '· 只截取需要的那一页导出为 PNG 再导入\n'
                '· 或把文字复制到「纯文本」模式\n\n'
                '当前版本尚未开放 PDF/DOC 的直接解析，'
                '继续会提示你改用截图或文本。'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('我知道了')),
            ),
          ],
        ),
      );
      if (go != true) return;
      _snack(tr('请截图后导入图片，或把文字粘贴到「纯文本」模式'));
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
    // 安卓端：出图走 WebView 线上渲染（方案 A）。注册到 pipeline 静态 hook，
    // 之后所有 pipeline.render() 调用（含自检冒烟）都会自动分流到这里。
    if (Platform.isAndroid) {
      OrbatPipeline.androidRenderHook = (normalizedJson, outputBase) async {
        if (!mounted) {
          return RenderResult(
              ok: false, error: '界面已关闭，无法出图', elapsed: Duration.zero);
        }
        final result = await Navigator.of(context).push<RenderResult>(
          MaterialPageRoute(
            builder: (_) => RenderWebViewPage(
              normalizedJson: normalizedJson,
              outputBase: outputBase,
              whiteBackground: widget.settings.whiteBackground,
            ),
          ),
        );
        return result ??
            RenderResult(ok: false, error: '出图被取消', elapsed: Duration.zero);
      };
      // 插件交接：Agent 可用 intent 直接触发批处理
      //   am start -a com.orbat.orbat_core.plugin.RUN
      const pluginChannel = MethodChannel('orbat/storage');
      pluginChannel.setMethodCallHandler((call) async {
        if (call.method == 'pluginRun') {
          // 先切回主界面（渲染页可能还压在栈顶）
          if (mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).popUntil((r) => r.isFirst);
          }
          await _runPluginBridge();
        }
      });
      // 冷启动时 intent 先于 Dart 到达：向原生拉取挂起的触发
      Timer(const Duration(milliseconds: 1200), () async {
        try {
          final pending =
              await pluginChannel.invokeMethod<bool>('consumePendingRun');
          if (pending == true) {
            await _runPluginBridge();
            return;
          }
        } catch (_) {}
        // 确定性的「打开即处理」：不依赖 intent 残留——只要权限已授且
        // 交接目录有待处理 JSON，打开 App 就自动跑批（手机端 Agent 主路径）
        Timer(const Duration(milliseconds: 800), () async {
          if (!mounted || _busy) return;
          try {
            final granted =
                await pluginChannel.invokeMethod<bool>('isManageStorageGranted');
            if (granted != true) return;
            PluginBridge.ensureDirs();
            if (PluginBridge.scanInbox().isNotEmpty) await _runPluginBridge();
          } catch (_) {}
        });
      });
    }
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
    if (!hasCliTask &&
        (!widget.settings.languageChosen || !widget.settings.modeChosen)) {
      // 首次启动：先问语言，再问模式。语言必须先问——模式对话框里的文案
      // 都是按当前界面语言渲染的，语言定早了才不会出现"中英跳变"。
      Timer(const Duration(milliseconds: 400), _firstRunFlow);
    } else {
      if (!hasCliTask &&
          widget.settings.mode != 2 &&
          widget.settings.apiKey.trim().isEmpty) {
        Timer(const Duration(milliseconds: 600), _showApiKeyGuide);
      }
      // 首次启动自动跑一次自检（含出图冒烟）：新用户第一件事就知道环境行不行
      if (!hasCliTask && !widget.settings.firstRunSelfCheckDone) {
        Timer(const Duration(milliseconds: 1800),
            () => _runSelfCheck(markFirstRun: true));
      }
    }
  }

  /// 首启无 Key 引导：告诉用户去哪申请、在哪填，一键直达设置。
  /// 首次启动引导链：语言 → 模式 →（需要才）Key → 自检
  ///
  /// 拆成一条链而不是各自起 Timer：两个对话框同时弹出会互相盖住，
  /// 而且模式对话框的文案要先按已确定的语言渲染。
  Future<void> _firstRunFlow() async {
    if (!mounted) return;
    if (!widget.settings.languageChosen) {
      await _showLanguageChooser();
      if (!mounted) return;
    }
    if (!widget.settings.modeChosen) {
      // 模式对话框内部会按分支接上 Key 引导 / 模式三说明 / 自检
      await _showModeChooser();
      return;
    }
    if (widget.settings.mode != 2 && widget.settings.apiKey.trim().isEmpty) {
      await _showApiKeyGuide();
    }
    if (!widget.settings.firstRunSelfCheckDone && mounted) {
      await _runSelfCheck(markFirstRun: true);
    }
  }

  /// 首次启动：选择界面语言
  ///
  /// 默认值来自系统语言（中文系统 → 中文，其他语言 → 英文），用户点一下就能改。
  /// 直接回车/点「继续」即接受默认值——不阻塞只想快点用起来的人。
  Future<void> _showLanguageChooser() async {
    if (!mounted) return;
    var picked = L10n.current;

    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setD) => AlertDialog(
          title: Text(tr('选择界面语言')),
          content: SizedBox(
            width: _dialogW(460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tf('检测到系统语言 {loc}，已默认选中对应语言；之后可随时在设置里更改。',
                      {'loc': L10n.systemLanguageLabel}),
                  style:
                      TextStyle(fontSize: 12, color: Theme.of(ctx2).hintColor),
                ),
                const SizedBox(height: 12),
                _pickOption(ctx2, () => setD(() => picked = AppLang.zh),
                    picked == AppLang.zh, '中文', tr('简体中文界面')),
                _pickOption(ctx2, () => setD(() => picked = AppLang.en),
                    picked == AppLang.en, 'English', 'English interface'),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx2).pop(true),
              child: Text(tr('继续')),
            ),
          ],
        ),
      ),
    );

    widget.settings.language = picked == AppLang.en ? 'en' : 'zh';
    widget.settings.languageChosen = true;
    applyLanguage(widget.settings.language);
    await widget.settings.save();
    AppLogger.instance
        .info('ui', '首次启动选择界面语言: ${widget.settings.language}');
  }

  /// 首次启动：选择使用模式
  ///
  /// 这一步放在最前面是有原因的：模式三（Agent 插件）**不需要 API Key**。
  /// 以前不管当前是什么模式，一律先弹「填 Key」，只用 Agent 的用户会以为必须买 Key。
  Future<void> _showModeChooser() async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setD) => AlertDialog(
          title: Text(tr('选择使用模式')),
          content: SizedBox(
            width: _dialogW(560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('三种模式可随时在设置里切换；只有模式一、模式二需要 DeepSeek API Key。'),
                  style:
                      TextStyle(fontSize: 12, color: Theme.of(ctx2).hintColor),
                ),
                const SizedBox(height: 12),
                _modeOption(ctx2, setD, 0, tr('模式一 · 纯软件'),
                    tr('在本软件界面里识图、校验、出图。需要 API Key。')),
                // 安卓端暂不支持模式二（无 CLI）
                if (!Platform.isAndroid)
                  _modeOption(ctx2, setD, 1, tr('模式二 · 软件 + CLI'),
                      tr('软件里配 Key，命令行 orbat-cli 供脚本 / Agent 调用。需要 API Key。'))
                else
                  _modeOption(ctx2, setD, 1, tr('模式二 · 软件 + CLI（安卓暂不支持）'),
                      tr('CLI 依赖桌面环境，安卓端二期再评估。请选模式一或模式三。')),
                _modeOption(ctx2, setD, 2, tr('模式三 · Agent 插件（无需 API Key）'),
                    tr('用 orbat-cli prompts 导出提示词交给外部 Agent 识图；本软件不配 Key。')),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx2).pop(false),
              child: Text(tr('稍后再说')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx2).pop(true),
              child: Text(tr('确定')),
            ),
          ],
        ),
      ),
    );

    widget.settings.modeChosen = true;
    setState(() {});
    await widget.settings.save();
    AppLogger.instance
        .info('ui', '首次启动选择模式: ${widget.settings.mode}（confirmed=$ok）');

    if (widget.settings.mode == 2) {
      if (mounted) await _explainAgentMode();
    } else if (widget.settings.apiKey.trim().isEmpty) {
      if (mounted) await _showApiKeyGuide();
    }
    if (!widget.settings.firstRunSelfCheckDone && mounted) {
      await _runSelfCheck(markFirstRun: true);
    }
  }

  /// 模式选项卡片（选中态高亮）
  Widget _modeOption(BuildContext ctx, StateSetter setD, int value, String title,
          String subtitle) =>
      _pickOption(ctx, () => setD(() => widget.settings.mode = value),
          widget.settings.mode == value, title, subtitle);

  /// 通用单选项卡片：语言、模式共用（只有一处样式，避免两套视觉）
  Widget _pickOption(BuildContext ctx, VoidCallback onTap, bool selected,
      String title, String subtitle) {
    final scheme = Theme.of(ctx).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? scheme.primary : Theme.of(ctx).dividerColor,
              width: selected ? 1.6 : 1,
            ),
            color: selected ? scheme.primary.withValues(alpha: 0.06) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: selected ? scheme.primary : Theme.of(ctx).hintColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11, color: Theme.of(ctx).hintColor)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 模式三说明（不弹 Key 引导，改讲 Agent 流程）
  Future<void> _explainAgentMode() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('模式三：不需要 API Key')),
        content: SizedBox(
          width: _dialogW(520),
          child: Text(
            tr('本软件不会向你要 Key。工作方式是：\n\n'
                '1. 用 orbat-cli prompts 导出识图提示词；\n'
                '2. 把提示词和图交给你的 Agent（它用自己的模型）；\n'
                '3. 把 Agent 产出的 JSON 贴回本软件，校验与出图仍然可用。\n\n'
                '之后想在界面里直接识图，随时在设置里切到模式一/二并填写 Key。'),
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('知道了')),
          ),
        ],
      ),
    );
  }

  Future<void> _showApiKeyGuide() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('先配置 API Key')),
        content: Text(tr('识图功能需要 DeepSeek API Key：\n\n'
            '1. 在 platform.deepseek.com 注册并创建 API Key；\n'
            '2. 点下方「打开设置」粘贴 Key；\n'
            '3. 出图功能不需要 Key，但需要安装 Node.js 24 或更高版本。\n\n'
            '之后可随时在右上角设置里修改。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('稍后再说')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openSettings();
            },
            child: Text(tr('打开设置')),
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
        _snack(tr('该文件不是有效的编制 JSON'));
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
      _snack(widget.settings.mode == 2
          ? tr('模式三由外部 Agent 识图，本软件不配 Key；要在界面识图请切到模式一/二并填写 Key')
          : tr('请先在右上角设置里填写 DeepSeek API Key'));
      return;
    }
    if (_inputMode == InputMode.textOnly && _textCtrl.text.trim().isEmpty) {
      _snack(tr('纯文本模式：请先粘贴或输入编制资料'));
      return;
    }
    if (_inputMode == InputMode.material &&
        _image == null &&
        _textCtrl.text.trim().isEmpty) {
      _snack(tr('请先选择资料图片，或在补充说明里填写内容'));
      return;
    }
    if (_inputMode == InputMode.material &&
        _image == null &&
        _textCtrl.text.trim().isEmpty) {
      _snack(tr('请先选择一张编制图，或输入文字资料'));
      return;
    }

    AppLogger.instance.section('生成编制');
    AppLogger.instance.info(
        'ui',
        '生成: image=${_image?.path ?? "无"} '
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
      forceChinese: widget.settings.forceChinese,
    );

    try {
      final useImage = _inputMode == InputMode.material && _image != null;
      final result = useImage
          ? await pipeline.fromImage(
              _image!,
              extraText:
                  _textCtrl.text.trim().isEmpty ? null : _textCtrl.text.trim(),
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
      _snack(tr('还没有可出图的编制数据'));
      return;
    }
    // 安卓走 WebView 线上渲染，不需要本地渲染脚本
    if (!Platform.isAndroid && widget.settings.renderScriptPath.trim().isEmpty) {
      _snack(tr('请在设置里指定渲染脚本 render_orbat.js 的路径'));
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
      forceChinese: widget.settings.forceChinese,
    );

    try {
      final base = _defaultOutputBase();
      final settings = widget.settings;
      // 产物开关：JSON 单独落盘（编辑页内容为准）
      String? savedJson;
      if (settings.emitJson) {
        final jsonPath = '$base.json';
        await File(jsonPath).writeAsString(
            _jsonText.isNotEmpty ? _jsonText : normalizeTreeJson(tree));
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
        try {
          await File(svgPath).delete();
        } catch (_) {}
        svgPath = null;
      }
      // PNG 不勾选但 SVG 勾选 → 删掉 PNG（纯 SVG 模式）
      var pngPath = result.pngPath;
      if (result.ok && !settings.emitPng && pngPath != null) {
        try {
          await File(pngPath).delete();
        } catch (_) {}
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
        AppLogger.instance.info('ui',
            '出图完成: $saved @ ${settings.outputDir.isEmpty ? "默认目录" : settings.outputDir} (${result.elapsed.inSeconds}s)');
        _appendLog('出图完成（$saved）：$base（${result.elapsed.inSeconds}s）');
        // 窄屏：出图完成后自动切到预览页，让用户直接看到图
        if (MediaQuery.of(context).size.width < 640) {
          setState(() => _mobilePane = 2);
        }
      } else {
        _appendLog('出图失败：${result.error}');
        _snack(tr('出图失败，详见下方日志'));
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
  /// GUI 默认落在 exe 同级「输出文件存档\」，用户可通过「更改目录」改到别处。
  String _defaultOutputBase() {
    final dir = outputDir;
    final name = _tree?.uniqueDesignation ?? '编制图';
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    return '$dir/${stamp}_$safe';
  }

  /// GUI 输出目录：优先用户设置，否则 exe 同级「输出文件存档」。
  ///
  /// 设置里的目录若已失效（移动/删除过），尝试重建；重建失败才回退默认，
  /// 避免出图直接报「目录不存在」。
  String get outputDir {
    final d = widget.settings.outputDir.trim();
    if (d.isNotEmpty && ensureDirExists(d)) return d;
    return ensureArchiveDir();
  }

  /// 插件交接模式（安卓端 Agent 外挂）：
  /// Agent 把编制 JSON 放 Download/orbat_inbox/ → 这里一键批量
  /// 校验 + 出图 → 产物与报告写 orbat_outbox/ → Agent 取走结果。
  Future<void> _runPluginBridge() async {
    if (!Platform.isAndroid) return;
    const channel = MethodChannel('orbat/storage');
    bool granted = false;
    try {
      granted =
          await channel.invokeMethod<bool>('isManageStorageGranted') ?? false;
    } catch (_) {}
    if (!granted) {
      try {
        await channel.invokeMethod('requestManageStorage');
      } catch (_) {}
      _snack(tr('请在系统设置允许「所有文件访问」后，返回再点一次「插件处理」'));
      return;
    }
    PluginBridge.ensureDirs();
    final files = PluginBridge.scanInbox();
    if (files.isEmpty) {
      _snack(tf('交接目录没有待处理 JSON：{p}', {'p': PluginBridge.inboxDir}));
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _stage = tf('插件处理中：{n} 个文件', {'n': files.length});
    });
    final pipeline = OrbatPipeline(
      apiKey: widget.settings.apiKey,
      renderScriptPath: widget.settings.renderScriptPath,
      whiteBackground: widget.settings.whiteBackground,
      forceChinese: widget.settings.forceChinese,
    );
    int okCount = 0;
    int renderOk = 0;
    // 状态信号：Agent 轮询 _status.json 判定开始/进度/完成
    await PluginBridge.writeStatus({
      'state': 'running',
      'total': files.length,
      'done': 0,
      'startedAt': DateTime.now().toIso8601String(),
    });
    try {
      var done = 0;
      for (final f in files) {
        final r = await PluginBridge.processOne(f,
            (nj, ob) => pipeline.render(parseTreeJson(nj)!, outputBase: ob));
        done++;
        if (r['ok'] == true) okCount++;
        if (r['render']['ok'] == true) renderOk++;
        await PluginBridge.writeStatus({
          'state': 'running',
          'total': files.length,
          'done': done,
          'current': r['file'],
        });
        _appendLog(tf('插件处理 {f}：校验{v}，出图{g}', {
          'f': r['file'],
          'v': r['ok'] == true
              ? tr('通过（红牌 0）')
              : '${tr('红牌')} ${(r['red'] as List).length}',
          'g': r['render']['ok'] == true ? tr('成功') : tr('失败'),
        }));
      }
      _snack(tf('插件处理完成：{n} 个，校验通过 {ok}，出图成功 {g}，产物在 orbat_outbox', {
        'n': files.length,
        'ok': okCount,
        'g': renderOk,
      }));
      await PluginBridge.writeStatus({
        'state': 'idle',
        'lastRun': {
          'total': files.length,
          'validated': okCount,
          'rendered': renderOk,
          'finishedAt': DateTime.now().toIso8601String(),
        },
      });
    } catch (e) {
      _appendLog('插件处理异常：$e');
      _snack('插件处理异常：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出 Agent 工作流提示词到 Download/orbat_docs/（模式三 · 安卓端）
  Future<void> _exportAgentPrompts() async {
    if (!Platform.isAndroid) return;
    try {
      final path = await PluginBridge.exportPrompts();
      _snack(tf('提示词已导出：{p}', {'p': path}));
      _appendLog('Agent 提示词已导出：$path');
    } catch (e) {
      _snack('导出失败：$e');
    }
  }

  Future<void> _exportJson() async {
    if (_jsonText.trim().isEmpty) {
      _snack(tr('还没有 JSON 可导出'));
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
    _snack(tr('已导出 JSON'));
  }

  Future<void> _exportPng() async {
    final src = _pngPath;
    if (src == null || !File(src).existsSync()) {
      _snack(tr('还没有出图，先点「出图」'));
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
    _snack(tr('已导出 PNG'));
  }

  /// 一键复制 PNG 到系统剪贴板。
  ///
  /// 首选原生通道：同时写「文件引用(CF_HDROP)」和「位图(CF_DIB)」，
  /// 因此粘到微信/QQ 是图片、粘到资源管理器是文件、粘到 Word 是图。
  /// 原生不可用时退回 PowerShell 的 Set-Clipboard（仅文件引用）。
  Future<void> _copyPng() async {
    final src = _pngPath;
    if (src == null || !File(src).existsSync()) {
      _snack(tr('还没有出图，先点「出图」'));
      return;
    }
    try {
      const ch = MethodChannel('orbat/clipboard');
      final ok = await ch.invokeMethod<bool>('copyImageFile', {'path': src});
      if (ok == true) {
        _appendLog('PNG 已复制到剪贴板：$src');
        _snack(tr('已复制 PNG，可直接粘贴到微信 / 文档'));
        return;
      }
      _appendLog('原生剪贴板返回失败，改用 PowerShell 兜底');
    } catch (e) {
      _appendLog('原生剪贴板不可用（$e），改用 PowerShell 兜底');
    }
    try {
      // 用环境变量传路径，彻底避开引号/中文转义问题
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-STA',
          '-Command',
          r'Set-Clipboard -LiteralPath $env:ORBAT_CLIP'
        ],
        environment: {'ORBAT_CLIP': src},
      );
      if (r.exitCode == 0) {
        _snack(tr('已复制 PNG 文件，可直接粘贴'));
        return;
      }
    } catch (e) {
      _appendLog('PowerShell 复制失败：$e');
    }
    // 最后兜底：至少把路径给出去，用户能自己找到文件
    await Clipboard.setData(ClipboardData(text: src));
    _snack('复制图片失败，已复制文件路径：$src');
  }

  /// 切换「全中文输出」并持久化（默认勾选；不勾选则保留原文称号/番号）
  Future<void> _toggleForceChinese() async {
    setState(
        () => widget.settings.forceChinese = !widget.settings.forceChinese);
    await widget.settings.save();
    AppLogger.instance
        .info('ui', '全中文输出: ${widget.settings.forceChinese ? "开" : "关（保留原文）"}');
  }

  /// 打开「输出文件存档」目录（不存在则先创建）
  Future<void> _openArchiveDir() async {
    final dir = outputDir;
    try {
      ensureDirExists(dir);
      await Process.run('explorer', [dir]);
    } catch (e) {
      _snack('打开失败：$e');
    }
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
      _snack(tr('日志未启用（目录不可写）'));
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
      _snack(tr('当前还没有日志文件'));
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
      ..writeln(
          '当前树: ${tree == null ? "无" : "${tree.count} 节点 / 层级 ${tree.maxDepth}"}')
      ..writeln('最近出图: ${_pngPath ?? "无"}')
      ..writeln('最近SVG: ${_svgPath ?? "无"}');
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    _snack(tr('诊断信息已复制到剪贴板'));
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
          title: Text(tr('有未保存的修改')),
          content: Text(tr('JSON 编辑页的内容还没点「应用」，重置后会丢失。\n继续吗？')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('继续重置')),
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
      _stage = tr('就绪');
    });
    _appendLog('已重置到初始状态（换新版本请关闭窗口后重新打开）');
  }

  /// 查看最近一次 API 对话：完整 prompt + 模型输出（观察/JSON/自检）+ 思考链 + 用量
  Future<void> _showConversation() async {
    final conv = DeepSeekClient.lastConversation;
    if (conv == null || conv.isEmpty) {
      _snack(tr('还没有 API 调用记录，先生成一次编制'));
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
                      Text(tr('最近一次 API 对话'),
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
                        tooltip: tr('复制完整响应'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: content));
                          _snack(tr('已复制完整响应'));
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
                                      Text(
                                          tr('模型原生思考链（reasoning_content）：'
                                              '仅 deepseek-reasoner 等模型会产生；'
                                              'deepseek-flash 默认关闭，此栏通常为空。'),
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
                                    codeBlock(
                                        (conv['system'] ?? '').toString()),
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
                  SizedBox(
                      width: 110,
                      child: Text(k, style: theme.textTheme.bodySmall)),
                  Text(v,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            );

        return AlertDialog(
          title: Text(tr('API 用量')),
          content: SizedBox(
            width: _dialogW(560),
            height: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('今日'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                row('调用次数', '${summary.todayCalls} 次'),
                row('输入 token', _fmt(summary.todayIn)),
                row('输出 token', _fmt(summary.todayOut)),
                row('合计 token', _fmt(summary.todayTokens),
                    color: theme.colorScheme.primary),
                const Divider(height: 20),
                Text(tr('本月'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                row('调用次数', '${summary.monthCalls} 次'),
                row('合计 token', _fmt(summary.monthTokens),
                    color: theme.colorScheme.primary),
                const Divider(height: 20),
                Text('最近 ${recent.length} 次调用',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Expanded(
                  child: recent.isEmpty
                      ? Center(
                          child: Text(tr('还没有调用记录'),
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
                                          style:
                                              const TextStyle(fontSize: 11))),
                                  SizedBox(
                                      width: 72,
                                      child: Text(e.scene,
                                          style:
                                              const TextStyle(fontSize: 11))),
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
                    title: Text(tr('清空统计？')),
                    content: Text(tr('会删除本机保存的全部用量记录，不可恢复。')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c2, false),
                          child: Text(tr('取消'))),
                      FilledButton(
                          onPressed: () => Navigator.pop(c2, true),
                          child: Text(tr('清空'))),
                    ],
                  ),
                );
                if (ok == true) {
                  await UsageStore.clear();
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: Text(tr('清空统计')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('关闭')),
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
  ///
  /// [markFirstRun] 首次启动自动跑时为 true：跑完记一个标记，以后不再自动弹。
  Future<void> _runSelfCheck({bool markFirstRun = false}) async {
    setState(() => _stage = tr('自检中…'));
    SelfCheckResult result;
    try {
      result = await SelfCheck.run(
        renderScriptPath: widget.settings.renderScriptPath,
        apiKey: widget.settings.apiKey,
        // 真渲染一次（约 15-25 秒）：把"能不能出图"从猜测变成结论
        smokeRender: true,
        outputDir: outputDir,
        mode: widget.settings.mode,
      );
    } catch (e) {
      _snack('自检失败：$e');
      setState(() => _stage = '就绪');
      return;
    }
    setState(() => _stage = '就绪');
    if (!mounted) return;

    _appendLog('自检完成：失败 ${result.failCount} 项，警告 ${result.warnCount} 项');
    if (markFirstRun) {
      widget.settings.firstRunSelfCheckDone = true;
      await widget.settings.save();
      _appendLog('首次启动自检已记录，后续可在顶部「自检」按钮手动触发');
    }

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
              Text(result.allOk
                  ? tr('环境正常')
                  : tf('发现 {n} 项问题', {'n': result.failCount})),
            ],
          ),
          content: SizedBox(
            width: _dialogW(560),
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
              child: Text(tr('知道了')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSettings() async {
    final keyCtrl = TextEditingController(text: widget.settings.apiKey);
    final scriptCtrl =
        TextEditingController(text: widget.settings.renderScriptPath);
    final modelCtrl = TextEditingController(text: widget.settings.model);
    int modeVal = widget.settings.mode;
    const modeNames = [
      '模式一 · 纯软件',
      '模式二 · 软件+CLI(配API)',
      '模式三 · Agent插件(无需API)'
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text(tr('设置')),
          content: ConstrainedBox(
            // 手机竖屏：内容总高超过屏幕（此前 BOTTOM OVERFLOWED 207px）→
            // 限高 72% + 可滚动；宽度仍用 _dialogW
            constraints: BoxConstraints(
              maxWidth: _dialogW(520),
              maxHeight: MediaQuery.of(context).size.height * 0.72,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                DropdownButtonFormField<int>(
                  initialValue: modeVal,
                  isExpanded: true, // 手机窄屏：长选项文本右溢 45px → 占满行宽+省略
                  decoration: InputDecoration(
                    labelText: tr('工作模式'),
                    helperText: tr(
                        '模式一：GUI 手动使用｜模式二：CLI 交给 Agent，软件配 API｜模式三：Agent 全权，软件不配 API'),
                    helperMaxLines: 3,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (var i = 0; i < modeNames.length; i++)
                      DropdownMenuItem(
                        value: i,
                        // 安卓端暂不支持模式二（无 CLI）
                        enabled: !(Platform.isAndroid && i == 1),
                        child: Text(
                          (Platform.isAndroid && i == 1)
                              ? '${modeNames[i]}（安卓暂不支持）'
                              : modeNames[i],
                          style: (Platform.isAndroid && i == 1)
                              ? TextStyle(color: Theme.of(ctx).hintColor)
                              : null,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    // 安卓端不允许选模式二
                    if (Platform.isAndroid && v == 1) return;
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
                    helperText: tr(modeVal == 2
                        ? '模式三由 AI Agent 调用自己的 API，本软件不需要 Key'
                        : '仅存于本机配置文件（DPAPI / 混淆存储）'),
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue:
                      SettingsStore.knownModels.containsKey(modelCtrl.text)
                          ? modelCtrl.text
                          : null,
                  isExpanded: true,
                  // 模式三灰化：模型由 Agent 决定，软件不调 API
                  disabledHint: Text(tr('模式三由 Agent 决定模型')),
                  decoration: InputDecoration(
                    labelText: tr('识图模型'),
                    helperText: tr(modeVal == 2
                        ? '模式三不使用本软件的识图模型'
                        : '任选预设，也可在下方手填自定义模型 id'),
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    ...SettingsStore.knownModels.entries.map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ),
                    DropdownMenuItem(
                        value: '__custom__', child: Text(tr('自定义…'))),
                  ],
                  onChanged: modeVal == 2
                      ? null
                      : (v) {
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
                    labelText: tr('模型 id（可手填）'),
                    hintText: 'deepseek-flash',
                    helperText: modeVal == 2 ? tr('模式三不使用本软件的识图模型') : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: widget.settings.language.isEmpty
                      ? 'auto'
                      : widget.settings.language,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '界面语言 / Language',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'auto', child: Text('跟随系统 / System')),
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                  ],
                  onChanged: (v) async {
                    widget.settings.language =
                        (v == null || v == 'auto') ? '' : v;
                    applyLanguage(widget.settings.language);
                    await widget.settings.save();
                    setDlgState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => showTutorialDialog(ctx),
                    icon: const Icon(Icons.menu_book_outlined, size: 16),
                    label: Text(tr('查看内置教程（纯文字）')),
                  ),
                ),
                const SizedBox(height: 12),
                // 渲染脚本与 node 说明仅桌面有意义；安卓走 WebView 渲染，隐藏以省高度
                if (!Platform.isAndroid) ...[
                  TextField(
                    controller: scriptCtrl,
                    decoration: InputDecoration(
                      labelText: tr('渲染脚本 render_orbat.js'),
                      helperText: tr('出图用的线上渲染脚本绝对路径'),
                      helperMaxLines: 2,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr('说明：出图必须联网，调用 spatialillusions.com 线上渲染器。\n'
                        '需要 node ≥ 24，脚本会自行探测。'),
                    style: TextStyle(fontSize: 12),
                  ),
                  const Divider(height: 24),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('日志与诊断'),
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
                      label: Text(tr('打开日志目录')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exportLog,
                      icon: const Icon(Icons.save_alt, size: 16),
                      label: Text(tr('导出本次日志')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _copyDiagnostics,
                      icon: const Icon(Icons.copy_all, size: 16),
                      label: Text(tr('复制诊断信息')),
                    ),
                  ],
                ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('取消')),
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
              child: Text(tr('保存')),
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
    // 窄屏（手机竖屏）：三面板并排放不下，改「分段切换」+ AppBar 收纳
    final narrow = MediaQuery.of(context).size.width < 640;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.account_tree_outlined, size: 22),
            if (!narrow) ...[
              const SizedBox(width: 10),
              Text(tr('编制图生成器'), style: TextStyle(fontSize: 18)),
            ],
            const SizedBox(width: 12),
            if (_busy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        actions: narrow ? _buildMobileActions(theme) : _buildDesktopActions(),
      ),
      body: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                  child: SegmentedButton<int>(
                    segments: [
                      ButtonSegment(
                          value: 0,
                          icon: Icon(Icons.edit_note_outlined, size: 16),
                          label: Text(tr('资料'))),
                      ButtonSegment(
                          value: 1,
                          icon: Icon(Icons.account_tree_outlined, size: 16),
                          label: Text(tr('编制树'))),
                      ButtonSegment(
                          value: 2,
                          icon: Icon(Icons.image_outlined, size: 16),
                          label: Text(tr('预览'))),
                    ],
                    selected: {_mobilePane},
                    onSelectionChanged: (s) =>
                        setState(() => _mobilePane = s.first),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _mobilePane,
                    children: [
                      _buildInputPane(theme),
                      _buildTreePane(theme),
                      _buildPreviewPane(theme),
                    ],
                  ),
                ),
              ],
            )
          : Row(
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

  /// 桌面端 AppBar 动作（原有布局，保持不变）
  List<Widget> _buildDesktopActions() => [
        TextButton.icon(
          onPressed: _busy ? null : _pickImage,
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(tr('选择图片')),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(tr('生成编制')),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          onPressed: _busy ? null : _render,
          icon: const Icon(Icons.photo_outlined, size: 18),
          label: Text(tr('出图')),
        ),
        const SizedBox(width: 10),
        IconButton(
          tooltip: tr('打开已有编制 JSON'),
          onPressed: _busy ? null : _openJson,
          icon: const Icon(Icons.folder_open_outlined),
        ),
        IconButton(
          tooltip: tr('API 用量（调用次数 / token 消耗）'),
          onPressed: _showUsage,
          icon: const Icon(Icons.data_usage_outlined),
        ),
        IconButton(
          tooltip: tr('查看 API 对话（观察/思考过程、JSON、自检、Prompt）'),
          onPressed: _showConversation,
          icon: const Icon(Icons.chat_bubble_outline),
        ),
        IconButton(
          tooltip: tr('内置教程（纯文字，随界面语言切换）'),
          onPressed: () => showTutorialDialog(context),
          icon: const Icon(Icons.menu_book_outlined),
        ),
        IconButton(
          tooltip: tr('环境自检（检查依赖与工具是否齐全）'),
          onPressed: _busy ? null : _runSelfCheck,
          icon: const Icon(Icons.health_and_safety_outlined),
        ),
        IconButton(
          tooltip: tr('切换主题'),
          onPressed: widget.onToggleTheme,
          icon: const Icon(Icons.brightness_6_outlined),
        ),
        IconButton(
          tooltip: tr('重置（清空当前内容，回到初始状态）'),
          onPressed: _busy ? null : _resetApp,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: tr('设置'),
          onPressed: _openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 8),
      ];

  /// 窄屏（手机）AppBar 动作：核心操作保留，其余收进「更多」菜单
  List<Widget> _buildMobileActions(ThemeData theme) => [
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: Text(tr('生成')),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _render,
          icon: const Icon(Icons.photo_outlined, size: 16),
          label: Text(tr('出图')),
        ),
        PopupMenuButton<String>(
          tooltip: tr('更多功能'),
          onSelected: (v) {
            switch (v) {
              case 'plugin':
                _runPluginBridge();
                break;
              case 'prompts':
                _exportAgentPrompts();
                break;
              case 'image':
                _pickImage();
                break;
              case 'json':
                _openJson();
                break;
              case 'usage':
                _showUsage();
                break;
              case 'conv':
                _showConversation();
                break;
              case 'tutorial':
                showTutorialDialog(context);
                break;
              case 'check':
                _runSelfCheck();
                break;
              case 'reset':
                _resetApp();
                break;
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
                value: 'plugin',
                child: ListTile(
                  leading: Icon(Icons.extension_outlined, size: 20),
                  title: Text(tr('插件处理 · Agent 交接'),
                      style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'prompts',
                child: ListTile(
                  leading: Icon(Icons.description_outlined, size: 20),
                  title: Text(tr('导出 Agent 提示词'),
                      style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'image',
                child: ListTile(
                  leading: Icon(Icons.image_outlined, size: 20),
                  title: Text(tr('选择图片'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'json',
                child: ListTile(
                  leading: Icon(Icons.folder_open_outlined, size: 20),
                  title: Text(tr('打开编制 JSON'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'usage',
                child: ListTile(
                  leading: Icon(Icons.data_usage_outlined, size: 20),
                  title: Text(tr('API 用量'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'conv',
                child: ListTile(
                  leading: Icon(Icons.chat_bubble_outline, size: 20),
                  title: Text(tr('API 对话'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'tutorial',
                child: ListTile(
                  leading: Icon(Icons.menu_book_outlined, size: 20),
                  title: Text(tr('教程'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'check',
                child: ListTile(
                  leading: Icon(Icons.health_and_safety_outlined, size: 20),
                  title: Text(tr('环境自检'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
            PopupMenuItem(
                value: 'reset',
                child: ListTile(
                  leading: Icon(Icons.refresh, size: 20),
                  title: Text(tr('重置'), style: TextStyle(fontSize: 14)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
          ],
        ),
        IconButton(
          tooltip: tr('切换主题'),
          onPressed: widget.onToggleTheme,
          icon: const Icon(Icons.brightness_6_outlined),
        ),
        IconButton(
          tooltip: tr('设置'),
          onPressed: _openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 4),
      ];

  Widget _buildInputPane(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<InputMode>(
            segments: [
              ButtonSegment(
                value: InputMode.material,
                icon: Icon(Icons.perm_media_outlined, size: 16),
                label: Text(tr('资料为主')),
              ),
              ButtonSegment(
                value: InputMode.textOnly,
                icon: Icon(Icons.text_fields, size: 16),
                label: Text(tr('纯文本')),
              ),
            ],
            selected: {_inputMode},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged:
                _busy ? null : (v) => setState(() => _inputMode = v.first),
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
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.3),
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
                            Text(tr('点击选择编制图'),
                                style: TextStyle(color: theme.hintColor)),
                            const SizedBox(height: 4),
                            Text('PNG / JPG',
                                style: TextStyle(
                                    fontSize: 11, color: theme.hintColor)),
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
                      tooltip: tr('移除'),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          _busy ? null : () => setState(() => _image = null),
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
                  _inputMode == InputMode.material
                      ? tr('补充说明（可选）')
                      : tr('编制资料（纯文本）'),
                  style: theme.textTheme.bodySmall),
              if (_inputMode == InputMode.textOnly) ...[
                const SizedBox(width: 6),
                Text(tr('（直接粘贴或手打单位清单）'),
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
                    ? tr('可补充：编制年代、番号体系、需要保留的原文缩写等。\n'
                        '大图也可以给结构提示：\n'
                        '总根：第1近卫机械化师\n'
                        '下辖：师部、第453机械化旅、第51机械化旅')
                    : tr('粘贴文字资料，例如：\n'
                        '第1步兵团（空中机动战斗团）\n'
                        '- 指挥与勤务连\n'
                        '  - 情报科\n'
                        '  - 通信排\n'
                        '- 轻型侦察连\n'
                        '……\n\n'
                        '每行一个单位，用缩进表示层级即可。'),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (_inputMode == InputMode.material) ...[
            const SizedBox(height: 10),
            Text(
              tr('提示：模型偏好中文单位名；外文资料可在补充说明里要求保留原始缩写。'),
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
          const SizedBox(height: 6),
          // 全中文输出开关（默认勾选）：决定 JSON 里是中文译名还是原文称号
          Tooltip(
            message: tr(widget.settings.forceChinese
                ? '勾选：名称与注释输出中文（外文单位译名）'
                : '未勾选：名称保留原文称号/番号，注释保留原文，便于与原图对照'),
            child: InkWell(
              onTap: _busy ? null : _toggleForceChinese,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Checkbox(
                        value: widget.settings.forceChinese,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: _busy ? null : (_) => _toggleForceChinese(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('全中文输出（名称与注释译成中文）'),
                        style:
                            theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
            // 手机窄屏：固定 240 宽 TabBar + 两个文字按钮会右溢 13px →
            // TabBar 收缩 + 按钮收图标
            child: LayoutBuilder(builder: (context, c) {
              final narrowBar = c.maxWidth < 640;
              return Row(
                children: [
                  Flexible(
                    child: TabBar(
                      isScrollable: narrowBar,
                      labelStyle: TextStyle(fontSize: 13),
                      labelPadding: narrowBar
                          ? const EdgeInsets.symmetric(horizontal: 10)
                          : EdgeInsets.zero,
                      tabs: [
                        Tab(height: 38, text: tr('结构')),
                        Tab(height: 38, text: tr('JSON 编辑')),
                        Tab(height: 38, text: tr('批量')),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_report != null) _reportChip(theme, _report!),
                  const Spacer(),
                  IconButton(
                    tooltip: tr('校验当前 JSON'),
                    onPressed: _jsonText.isEmpty ? null : _validateEditedJson,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.rule_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: tr('导出编制 JSON'),
                    onPressed: _jsonText.isEmpty ? null : _exportJson,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.download_outlined, size: 18),
                  ),
                ],
              );
            }),
          ),
          Expanded(
            child: TabBarView(
              children: [
                (_tree == null && _jsonText.isEmpty)
                    ? _emptyHint(theme, tr('生成后会在这里显示编制结构\n每个节点都会标注 SIDC 解读结果'))
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
      forceChinese: settings.forceChinese,
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
    await File(jsonPath)
        .writeAsString(gen.rawJson ?? normalizeTreeJson(gen.tree!));

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
      _snack(tr('请先添加图片'));
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
      _snack(tr('无法读取该结果'));
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
    _snack(tr('已载入结果，切到「结构」查看'));
  }

  /// 显示最近一次载入的差异
  Future<void> _showDiff() async {
    final diff = _lastDiff;
    if (diff == null) {
      _snack(tr('还没有可对比的结果（先从批量列表载入一个）'));
      return;
    }
    if (diff.isEmpty) {
      _snack(tr('两次结果没有差异'));
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
              child: Text(tr('关闭')),
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
                label: Text(tr('添加图片')),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: (_batchBusy || tasks.isEmpty) ? null : _startBatch,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(_batchBusy ? tr('处理中…') : tr('开始批量')),
              ),
              if (_batchBusy)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: TextButton(
                    onPressed: () => setState(() => queue?.cancel()),
                    child: Text(tr('取消')),
                  ),
                ),
              const Spacer(),
              if (queue != null && tasks.isNotEmpty)
                Text(
                    '${queue.doneCount}/${tasks.length} 完成 · 失败 ${queue.failedCount}',
                    style: theme.textTheme.bodySmall),
              if (_lastDiff != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _showDiff,
                  icon: const Icon(Icons.compare_arrows, size: 16),
                  label: Text(tr('对比')),
                ),
              ],
              if (tasks.isNotEmpty)
                IconButton(
                  tooltip: tr('清空列表'),
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
              tr('批量识图 + 自动出图\n\n'
                  '点「添加图片」一次选多张，程序会串行处理：\n'
                  '· 每张自动生成 JSON + PNG + SVG，存到图片同目录\n'
                  '· 失败的可单独重试，不影响其他任务\n'
                  '· 点击已完成的结果可载入到左侧，再点「对比」看差异'),
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
                  BatchStatus.rendering =>
                    Colors.blue,
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
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                            tooltip: tr('重试这一张'),
                            onPressed:
                                _batchBusy ? null : () => _retryBatchTask(t.id),
                            icon: const Icon(Icons.replay, size: 18),
                          ),
                        if (t.status == BatchStatus.done && t.jsonPath != null)
                          IconButton(
                            tooltip: tr('载入这个结果'),
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
      return TreeView(
        root: _tree!,
        report: _report,
        focusPath: _focusPath,
        onEditNode: _editNode,
      );
    }
    // 手改 JSON 后没有树对象时，尝试从文本解析出一棵临时树
    final parsed = parseTreeJson(_jsonText);
    if (parsed == null) {
      return _emptyHint(theme, tr('JSON 无法解析为编制树\n请切到「JSON 编辑」检查语法'));
    }
    return TreeView(
      root: parsed,
      report: OrbatValidator.validate(parsed),
      focusPath: _focusPath,
      onEditNode: _editNode,
    );
  }

  /// 从 JSON 面板挑一个单位来编辑
  Future<void> _pickNodeToEdit() async {
    final tree = _tree;
    if (tree == null) {
      _snack(tr('还没有编制树，先识图或载入 JSON'));
      return;
    }
    final rows = <({OrbatNode node, String path, int depth})>[];
    void walk(OrbatNode n, String path, int depth) {
      rows.add((node: n, path: path, depth: depth));
      for (final c in n.children) {
        walk(c, '$path/${c.uniqueDesignation}', depth + 1);
      }
    }

    walk(tree, '根', 0);
    final picked = await showDialog<({OrbatNode node, String path})>(
      context: context,
      builder: (ctx) {
        final query = ValueNotifier<String>('');
        return AlertDialog(
          title: Text(tr('选择一个单位')),
          content: SizedBox(
            width: _dialogW(560),
            height: 420,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: tr('按名称筛选…'),
                  ),
                  onChanged: (v) => query.value = v.trim().toLowerCase(),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: query,
                    builder: (ctx2, q, _) {
                      final shown = q.isEmpty
                          ? rows
                          : rows
                              .where((r) => r.node.uniqueDesignation
                                  .toLowerCase()
                                  .contains(q))
                              .toList();
                      return ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (ctx3, i) {
                          final r = shown[i];
                          return InkWell(
                            onTap: () => Navigator.of(ctx)
                                .pop((node: r.node, path: r.path)),
                            child: Padding(
                              padding: EdgeInsets.only(
                                  left: 8.0 + r.depth * 14,
                                  top: 7,
                                  bottom: 7,
                                  right: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      tr(r.node.uniqueDesignation.isEmpty
                                          ? '(无名)'
                                          : r.node.uniqueDesignation),
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (r.node.additionalInformation.isNotEmpty)
                                    Flexible(
                                      child: Text(
                                        r.node.additionalInformation,
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(ctx3).hintColor),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(tr('取消'))),
          ],
        );
      },
    );
    if (picked != null && mounted) {
      await _editNode(picked.node, picked.path);
    }
  }

  /// 编辑单个单位的名称 / 注释 / 编码（补丁式写回树）
  Future<void> _editNode(OrbatNode node, String path) async {
    final nameCtrl = TextEditingController(text: node.uniqueDesignation);
    final noteCtrl = TextEditingController(text: node.additionalInformation);
    final sidcCtrl = TextEditingController(text: node.sidc);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setD) {
          final usage = measureNote(noteCtrl.text);
          return AlertDialog(
            title: Text(tr('编辑单位')),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(path,
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(ctx2).hintColor,
                          fontFamily: 'Consolas')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: tr('单位名称 / 番号'),
                      isDense: true,
                      border: OutlineInputBorder(),
                      helperText: tr('名称里不能有「空格+左括号」（渲染器会卡死）'),
                      helperStyle: TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    onChanged: (_) => setD(() {}),
                    decoration: InputDecoration(
                      labelText: tr('注释（驻地或职能短名）'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      helperText:
                          '上限 $kNoteMaxCjk 汉字 / $kNoteMaxLetters 字母 · 当前 ${usage.label}',
                      helperStyle: TextStyle(
                        fontSize: 11,
                        color: usage.ok ? null : Colors.orange,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: sidcCtrl,
                    style: const TextStyle(fontFamily: 'Consolas'),
                    decoration: InputDecoration(
                      labelText: tr('SIDC（30 位数字）'),
                      isDense: true,
                      border: OutlineInputBorder(),
                      helperText: tr('不确定就留原值；保存后会自动纠正明显不一致的位'),
                      helperStyle: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx2).pop(false),
                  child: Text(tr('取消'))),
              FilledButton(
                  onPressed: () => Navigator.of(ctx2).pop(true),
                  child: Text(tr('保存'))),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;
    await _applyNodeEdit(path, node, nameCtrl.text.trim(), noteCtrl.text.trim(),
        sidcCtrl.text.trim());
  }

  /// 编辑结果作为补丁写回树，并同步 JSON 文本与校验结果
  Future<void> _applyNodeEdit(String path, OrbatNode original, String name,
      String note, String sidc) async {
    final tree = _tree;
    if (tree == null) return;
    final patch = NodePatch(
      path: path,
      name: name != original.uniqueDesignation ? name : null,
      note: note != original.additionalInformation ? note : null,
      sidc: sidc != original.sidc ? sidc : null,
    );
    if (patch.isEmpty) {
      _snack(tr('没有改动'));
      return;
    }
    final res = applyPatches(tree, [patch]);
    if (!res.ok) {
      _snack(tr('路径未命中，未修改（树可能已变化，请刷新后重试）'));
      return;
    }
    final fixed = OrbatAutoFix.apply(res.tree);
    final report = OrbatValidator.validate(fixed);
    setState(() {
      _tree = fixed;
      _report = report;
      _jsonText = normalizeTreeJson(fixed);
      _jsonCtrl.text = _jsonText;
      _focusPath = null;
    });
    _appendLog('已修改单位：$path（红牌 ${report.redCount}，警告 ${report.warnCount}）');
    _snack('已保存：$path');
  }

  Widget _buildJsonEditor(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 13, color: theme.hintColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  tr('可以直接改下面的文本；也可以点右侧按单位改名称/注释（会同步回树）'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontSize: 11, color: theme.hintColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _tree == null ? null : _pickNodeToEdit,
                icon: const Icon(Icons.edit_note, size: 16),
                label: Text(tr('按单位编辑'), style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: TextField(
              controller: _jsonCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                  fontFamily: 'Consolas', fontSize: 12, height: 1.5),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(10),
                hintText: tr('生成的 JSON 会出现在这里，可直接修改后点「校验」或「出图」'),
                helperText: tr('修改后会以文本为准出图；点「校验」可检查红牌问题'),
                helperStyle: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
              onChanged: (v) => _jsonText = v,
            ),
          ),
        ],
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
      _snack(tr('没有校验问题'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(tf('校验问题（{n}）', {'n': report.issues.length})),
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
                child: Text(tr('清除高亮')),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('关闭')),
            ),
          ],
        );
      },
    );
  }

  bool get _showProgressPanel =>
      _rendering || _renderStageName == '失败' || _renderStageName == '异常';

  /// 产物勾选 chip
  Widget _outputChip(
      String label, bool value, Future<void> Function(bool) onChanged) {
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
    _snack(tf('输出目录：{p}', {'p': result}));
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
          // 窄窗口自适应：预览栏被拖窄时，右侧按钮收成图标（Tooltip 保留说明），
          // 否则「导出 PNG / 复制 PNG」会被窗口边缘裁掉。
          child: LayoutBuilder(builder: (context, constraints) {
            final compact = constraints.maxWidth < 560;
            final hideTitle = constraints.maxWidth < 430;
            // Wrap：手机窄屏放不下时自动换行，桌面宽屏仍是一行（原来 Row 会溢出 29px）
            return Wrap(
              spacing: 2,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!hideTitle) ...[
                  Text(tr('出图成品'), style: theme.textTheme.titleSmall),
                  const SizedBox(width: 8),
                ],
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
                  message: tr('开=白底 PNG；关=透明底（可叠自定义背景图）'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(tr('白底'),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: widget.settings.whiteBackground
                                  ? null
                                  : theme.hintColor)),
                      Switch(
                        value: widget.settings.whiteBackground,
                        onChanged: _busy
                            ? null
                            : (v) async {
                                setState(
                                    () => widget.settings.whiteBackground = v);
                                await widget.settings.save();
                                AppLogger.instance
                                    .info('ui', 'PNG 白底开关: ${v ? "开" : "关"}');
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (compact)
                  IconButton(
                    tooltip: tr('导出 PNG 到指定位置'),
                    onPressed: _exportPng,
                    icon: const Icon(Icons.download_outlined, size: 18),
                  )
                else
                  TextButton.icon(
                    onPressed: _exportPng,
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: Text(tr('导出 PNG')),
                  ),
                const SizedBox(width: 4),
                // 一键复制：出图后直接把图片放进剪贴板，粘到微信/文档即可
                if (compact)
                  IconButton(
                    tooltip: tr('复制当前 PNG 到剪贴板，可直接粘贴到微信 / Word'),
                    onPressed: _pngPath == null ? null : _copyPng,
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                  )
                else
                  Tooltip(
                    message: tr('把当前 PNG 复制到剪贴板，可直接粘贴到微信 / Word'),
                    child: TextButton.icon(
                      onPressed: _pngPath == null ? null : _copyPng,
                      icon: const Icon(Icons.copy_all_outlined, size: 16),
                      label: Text(tr('复制 PNG')),
                    ),
                  ),
              ],
            );
          }),
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
                  tf('输出目录：{p}', {'p': outputDir}),
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Tooltip(
                message: tr('在资源管理器里打开产物所在文件夹'),
                child: TextButton.icon(
                  onPressed: _openArchiveDir,
                  icon: const Icon(Icons.folder_open_outlined, size: 15),
                  label:
                      Text(tr('打开存档目录'), style: const TextStyle(fontSize: 11)),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _pickOutputDir,
                child: Text(tr('更改目录'), style: TextStyle(fontSize: 11)),
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
                      ? tr('正在出图…\n进度见上方，完整日志在下方')
                      : tr('点顶部「出图」调用线上渲染器\n需要联网，约 15-60 秒'),
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
    final tail =
        recent.length <= 6 ? recent : recent.sublist(recent.length - 6);

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
                  tooltip: tr('打开完整日志'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 24),
                  onPressed: () {
                    _appendLog('完整日志：$_lastRenderLogPath');
                    _snack(tf('完整日志：{p}', {'p': _lastRenderLogPath}));
                  },
                  icon: const Icon(Icons.description_outlined, size: 15),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value:
                  _renderProgress <= 0 ? null : _renderProgress.clamp(0.0, 1.0),
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
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.3),
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
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
            child: Row(
              children: [
                Text(tr('运行日志'), style: theme.textTheme.bodySmall),
                const Spacer(),
                IconButton(
                  tooltip: tr('复制日志'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _log.join('\n')));
                    _snack(tr('日志已复制'));
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
    // SafeArea：手势导航条会盖住 30px 高的状态栏文字
    return SafeArea(
      top: false,
      child: Container(
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
            tf('模型 {m}', {'m': widget.settings.model}),
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
        ],
      ),
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
