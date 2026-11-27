import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/logger.dart';
import 'i18n/l10n.dart';
import 'ui/l10n_ui.dart';
import 'ui/home_page.dart';
import 'services/settings_store.dart';

/// 单实例锁：绑定本机固定端口，进程退出时系统自动释放。
/// 比锁文件可靠——崩溃/强杀后端口一定会释放，不会留下"假锁"导致再也打不开。
/// 依次尝试 47821-47823：别的软件恰好占用 47821 时不应让用户无法启动
/// （宁可极小概率出现双实例，也不把"端口被占"误判成"已在运行"）。
/// 持有引用防止 ServerSocket 被 GC 回收后关闭端口锁（仅赋值不读取，忽略 lint）。
// ignore: unused_element
ServerSocket? _instanceLock;

/// 全局导航 key：供未捕获异常处理器在任意位置弹出提示。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

bool _fatalDialogVisible = false;
DateTime? _lastFatalDialogAt;

/// 安装全局异常兜底：日志 + 一次性提示，不吞掉原始 Flutter 错误处理。
void _installGlobalErrorHandlers() {
  final void Function(FlutterErrorDetails)? original = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.instance.error(
      'flutter',
      '未捕获异常: ${details.exception}',
      details.exception,
      details.stack,
    );
    try {
      _showFatalError(details.exception);
    } catch (_) {}
    original?.call(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.instance.error('platform', '未捕获异常: $error', error, stack);
    try {
      _showFatalError(error);
    } catch (_) {}
    return true;
  };
}

void _showFatalError(Object error) {
  final DateTime now = DateTime.now();
  if (_fatalDialogVisible) return;
  final DateTime? last = _lastFatalDialogAt;
  if (last != null && now.difference(last) < const Duration(seconds: 3)) {
    return;
  }
  final BuildContext? context = navigatorKey.currentContext;
  if (context == null) return;

  _fatalDialogVisible = true;
  _lastFatalDialogAt = now;
  final String logPath = AppLogger.instance.currentLogPath ?? '（日志不可用）';
  Future<void>(() async {
    try {
      if (!context.mounted) {
        _fatalDialogVisible = false;
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(tr('出错了')),
          content: Text('${_shortError(error)}\n\n${tr('日志')}: $logPath'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(tr('知道了')),
            ),
          ],
        ),
      );
    } catch (e) {
      AppLogger.instance.error('fatal-ui', '显示错误提示失败: $e');
    } finally {
      _fatalDialogVisible = false;
    }
  });
}

String _shortError(Object error) {
  final String s = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

Future<bool> _acquireSingleInstanceLock() async {
  for (final port in [47821, 47822, 47823]) {
    try {
      _instanceLock = await ServerSocket.bind('127.0.0.1', port);
      return true;
    } catch (_) {}
  }
  return false; // 连续三个端口都绑不上 = 确实已有实例在跑
}

Future<void> main(List<String> args) async {
  // 关键：把工作目录固定到 exe 所在目录。
  // Flutter 应用查找 data/ 等资源依赖工作目录，而"一键重启"用 detached 方式拉起新进程时
  // 工作目录可能继承自父进程或系统默认，导致新实例找不到 data/ 而立即崩溃
  // （表现为：日志记了"新进程已启动 pid=xxx"，但进程不在、也没有新实例的启动日志）。
  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    if (File('${exeDir.path}${Platform.pathSeparator}data').existsSync()) {
      Directory.current = exeDir.path;
    }
  } catch (_) {}

  WidgetsFlutterBinding.ensureInitialized();
  // 安卓端：确定应用私有目录，配置/日志才有可写的落点。
  // 不用 path_provider：其 2.3.x 的 JNI 实现在部分机型（HyperOS 实测）抛
  // ClassNotFoundException。Directory.systemTemp 在安卓 = <数据根>/cache，
  // 反推数据根后落 files/（稳定、重装不清、免插件）。
  if (Platform.isAndroid) {
    try {
      final dataRoot = Directory(Directory.systemTemp.path).parent.path;
      final cfg = Directory('$dataRoot/files/config');
      if (!cfg.existsSync()) cfg.createSync(recursive: true);
      SettingsStore.androidConfigDir = cfg;
    } catch (_) {}
  }
  await AppLogger.instance.init();
  _installGlobalErrorHandlers();

  // 单实例检查：同一时间只允许一个程序。
  // 命令行自动任务（--generate/--render）在已有实例时静默退出，
  // 避免批处理被弹窗打断；手动双击则在下面弹窗提示并退出。
  final locked = await _acquireSingleInstanceLock();
  AppLogger.instance.info('app', '单实例锁: ${locked ? "已获取" : "已有实例占用"}');
  if (!locked) {
    final isTask = args.contains('--generate') || args.contains('--render');
    if (!isTask) {
      // 用第一帧显示提示，2.5 秒后自动退出
      runApp(const _AlreadyRunningApp());
      Future<void>.delayed(const Duration(seconds: 3), () => exit(0));
    }
    return;
  }

  AppLogger.instance.info('app', '应用启动 | args=$args');
  final settings = await SettingsStore.load();
  // Android 不支持模式二（软件+CLI）；旧配置回退到模式一。
  if (Platform.isAndroid && settings.mode == 1) {
    settings.mode = 0;
    await settings.save();
    AppLogger.instance.info('app', 'Android 不支持模式二，已回退到模式一');
  }
  // 安卓端：输出目录默认用「输出文件存档」，落应用数据根 files/（同上反推，
  // 稳定可写；外部私有目录在本机不可用，公共目录需权限——统一走应用私有）
  if (Platform.isAndroid &&
      (settings.outputDir.trim().isEmpty ||
          settings.outputDir.contains('code_cache'))) {
    try {
      final dataRoot = Directory(Directory.systemTemp.path).parent.path;
      final arch = Directory('$dataRoot/files/输出文件存档');
      if (!arch.existsSync()) arch.createSync(recursive: true);
      final probe = File('${arch.path}/.orbat_probe');
      await probe.writeAsString('ok');
      await probe.delete();
      settings.outputDir = arch.path;
      await settings.save();
      AppLogger.instance.info('app', '安卓默认输出目录: ${arch.path}');
    } catch (_) {}
  }
  // 界面语言：'zh'/'en'，空 = 跟随系统
  L10n.apply(settings.language);
  AppLogger.instance.info(
    'app',
    '配置加载完成 | model=${settings.model} '
        '| key=${AppLogger.keyFingerprint(settings.apiKey)}',
  );
  // 支持 `启动.exe <某编制.json>` 直接打开；`<某图片.png> --generate` 直接识图
  final jsonArg = args.where((a) => !a.startsWith('--')).toList();
  // split('.').last 返回的是不带点的扩展名（jpg），列表也必须用不带点的形式
  const imageExts = ['png', 'jpg', 'jpeg', 'webp', 'bmp'];
  final firstExt =
      jsonArg.isNotEmpty ? jsonArg.first.toLowerCase().split('.').last : '';
  final isImage = imageExts.contains(firstExt);
  final pathExists = jsonArg.isNotEmpty && File(jsonArg.first).existsSync();
  final initialJson = pathExists && !isImage ? jsonArg.first : null;
  // `--render` 载入 JSON 后自动出图（便于批量/自检）
  final autoRender = args.contains('--render');
  // `--generate` 传入图片路径时自动识图（软件本体的命令行入口，与 CLI 等价）
  final autoGenerate = args.contains('--generate');
  final imageArg = pathExists && isImage ? jsonArg.first : null;
  AppLogger.instance.info(
    'app',
    '命令行参数解析: jsonArg=$jsonArg, initialJson=$initialJson, '
        'initialImage=$imageArg, autoRender=$autoRender, autoGenerate=$autoGenerate',
  );
  runApp(
    OrbatApp(
      settings: settings,
      initialJsonPath: initialJson,
      autoRender: autoRender,
      initialImagePath: imageArg,
      autoGenerate: autoGenerate,
    ),
  );
}

class OrbatApp extends StatefulWidget {
  final SettingsStore settings;
  final String? initialJsonPath;
  final bool autoRender;
  final String? initialImagePath;
  final bool autoGenerate;
  const OrbatApp({
    super.key,
    required this.settings,
    this.initialJsonPath,
    this.autoRender = false,
    this.initialImagePath,
    this.autoGenerate = false,
  });

  @override
  State<OrbatApp> createState() => _OrbatAppState();
}

// 统一字体：微软雅黑。系统自带、零体积，中文和西文（含俄文字母、数字）字重一致，
// 避免默认 Segoe UI 在中文回退时出现行高与字形跳变。
const _uiFont = 'Microsoft YaHei';
const _fontFallback = <String>['Microsoft YaHei', 'Segoe UI', 'SimSun'];
const _seed = Color(0xFF2E6BE6);

final ThemeData _lightTheme = ThemeData(
  fontFamily: _uiFont,
  fontFamilyFallback: _fontFallback,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.light,
  ),
  useMaterial3: true,
);

final ThemeData _darkTheme = ThemeData(
  fontFamily: _uiFont,
  fontFamilyFallback: _fontFallback,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  ),
  useMaterial3: true,
  scaffoldBackgroundColor: const Color(0xFF15171C),
);

class _OrbatAppState extends State<OrbatApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  // 缓存 HomePage 实例：主题切换只重建 MaterialApp，不让整个主页随根 setState 重跑 build。
  // 语言修订号变化时才换新实例，保证界面文字照常刷新。
  HomePage? _homePage;
  int _homeRevision = -1;

  HomePage _homeFor(int revision) {
    if (_homePage == null || _homeRevision != revision) {
      _homeRevision = revision;
      _homePage = HomePage(
        settings: widget.settings,
        initialJsonPath: widget.initialJsonPath,
        autoRender: widget.autoRender,
        initialImagePath: widget.initialImagePath,
        autoGenerate: widget.autoGenerate,
        onToggleTheme: _toggleTheme,
      );
    }
    return _homePage!;
  }

  void _toggleTheme() => setState(() {
        _themeMode =
            _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
      });

  @override
  Widget build(BuildContext context) {
    // 语言切换时整棵树重建（字典命中即换成英文，漏译回退中文）
    return ValueListenableBuilder<int>(
      valueListenable: l10nRevision,
      builder: (context, revision, __) => _buildApp(L10n.current, revision),
    );
  }

  Widget _buildApp(AppLang lang, int revision) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: tr('编制图生成器'),
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      themeAnimationDuration: Duration.zero,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      home: _homeFor(revision),
    );
  }
}

/// 供 UI 判断平台能力
bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 已有实例时的提示页（短暂显示后自动退出）
class _AlreadyRunningApp extends StatelessWidget {
  const _AlreadyRunningApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.info_outline,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                tr('编制图生成器已在运行'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(tr('请切换到已打开的窗口。此窗口即将关闭。'), style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
