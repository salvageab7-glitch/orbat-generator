/// 配置存储 —— API Key、渲染脚本路径、上次使用的目录
///
/// 带 schema 版本号：配置文件结构变化时能识别并迁移，不丢用户已有设置。
///
/// API Key 使用 Windows DPAPI 或 Android Keystore；旧 XOR 格式仅读取迁移，不再写入。
library;

import 'dart:convert';
import 'dart:io';

import '../core/logger.dart';
import '../core/secret_store.dart';

class SettingsStore {
  /// 配置文件 schema 版本。新增字段/改语义时递增，并在 _migrate 里写迁移逻辑。
  static const int currentConfigVersion = 7;

  /// 已知模型预设（id → 显示名）。可自由填写不在列表里的模型 id。
  static const Map<String, String> knownModels = {
    'deepseek-flash': 'DeepSeek Flash（快，推荐）',
    'deepseek-chat': 'DeepSeek Chat（稳）',
    'deepseek-reasoner': 'DeepSeek Reasoner（推理强，慢）',
  };

  String _apiKey;
  bool _apiKeyFromEnvironment = false;

  String get apiKey => _apiKey;

  set apiKey(String value) {
    _apiKey = value;
    _apiKeyFromEnvironment = false;
  }

  String model;
  String renderScriptPath;
  String lastDir;

  /// PNG 是否白底（false = 透明底，方便叠自定义背景图）
  bool whiteBackground;

  /// 输出目录（空 = 用默认：exe 同级「输出文件存档\」）。
  /// 用户可通过「更改目录」按钮设置，持久化到 config.json。
  String outputDir;

  /// 工作模式：0=纯软件 1=混合(软件+CLI) 2=插件(Agent全权)
  /// 默认 0（纯软件模式）
  int mode;

  /// 产物开关：出图时输出哪些文件
  bool emitJson;
  bool emitPng;
  bool emitSvg;

  /// 全中文输出（v0.4，默认开）：
  ///   true  → AI 输出的名称与注释都是中文（外文单位译名）
  ///   false → 保留原文称号/番号/注释，便于与原图逐字对照
  bool forceChinese;

  /// 界面语言：'zh' / 'en'（默认跟随系统）
  String language;

  /// 是否已跑过首次启动自检（只自动跑一次，之后可在界面手动触发）
  bool firstRunSelfCheckDone;

  /// 首次启动是否已经选过使用模式（选了就不再弹模式选择）
  bool modeChosen;

  /// 首次启动是否已经选过界面语言（选过就不再弹语言选择）
  ///
  /// 注意与 [language] 的区别：`language` 是当前值（''=跟随系统），
  /// 这里是"问过没有"。新装用户 language 为空且 languageChosen=false，
  /// 启动时才会弹一次语言选择框。
  bool languageChosen;

  /// 配置文件的 schema 版本（0 表示老版本、还没打版本号）
  int configVersion;

  SettingsStore({
    String apiKey = '',
    this.model = 'deepseek-flash',
    this.renderScriptPath = '',
    this.lastDir = '',
    this.whiteBackground = true,
    this.outputDir = '',
    this.mode = 0,
    this.emitJson = true,
    this.emitPng = true,
    this.emitSvg = false,
    this.forceChinese = true,
    this.language = '',
    this.firstRunSelfCheckDone = false,
    this.modeChosen = false,
    this.languageChosen = false,
    this.configVersion = currentConfigVersion,
  }) : _apiKey = apiKey;

  /// 安卓端配置目录（应用私有 support 目录下 config/）。
  /// main() 启动时由 path_provider 初始化；null = 尚未初始化（退化到回退目录）。
  static Directory? androidConfigDir;

  /// 配置文件目录：%APPDATA%\OrbatGenerator（Windows）
  /// / 应用私有目录 config/（Android，path_provider）
  /// / ~/.config/orbat（其他，回退）
  static Directory get configDir {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory('$appData/OrbatGenerator');
      }
    }
    if (Platform.isAndroid) {
      final d = androidConfigDir;
      if (d != null) return d;
      // path_provider 尚未初始化时退到应用 cache（logger 也用它），至少可写
      return Directory('${Directory.systemTemp.path}/orbat-config');
    }
    final home = Platform.environment['HOME'] ?? '.';
    return Directory('$home/.config/orbat');
  }

  static File get _file => File('${configDir.path}/config.json');

  static Future<SettingsStore> load() async {
    final store = SettingsStore(renderScriptPath: await _guessRenderScript());
    // 环境变量优先：分发给其他用户 / AI Agent 调用时，本机往往没有
    // config.json，用 DEEPSEEK_API_KEY 环境变量传 key 最方便，也避免在
    // 共享机器上把 key 写进配置文件。放在 if 外，无配置文件时同样生效。
    final envKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
    if (envKey.trim().isNotEmpty) {
      store.apiKey = envKey.trim();
      store._apiKeyFromEnvironment = true;
    }
    var needsConfigRewrite = false;
    try {
      if (await _file.exists()) {
        final map =
            jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        // 仅当环境变量没提供 key 时才用配置文件里的
        if (store.apiKey.isEmpty) {
          final raw = (map['apiKey'] ?? '').toString();
          store.apiKey = await SecretStore.open(raw);
          if (raw.isNotEmpty && SecretStore.isLegacy(raw)) {
            // 老格式（固定 XOR）只为迁移而读取；加载后立即尝试安全重写。
            needsConfigRewrite = store.apiKey.isNotEmpty;
            AppLogger.instance.info('secret', '检测到旧格式密钥，将迁移到平台安全存储');
          }
        }
        store.model = (map['model'] ?? 'deepseek-flash').toString();
        final p = (map['renderScriptPath'] ?? '').toString();
        // 只在配置里的路径真实存在时才采用。否则保留 _guessRenderScript()
        // 探测到的 exe 同级 runtime/ —— 这样软件换机器/换目录分发后，
        // 旧的绝对路径失效时会自动回退到自带脚本，不会卡在无效路径上。
        if (p.isNotEmpty && File(p).existsSync()) store.renderScriptPath = p;
        store.lastDir = (map['lastDir'] ?? '').toString();
        store.whiteBackground = map['whiteBackground'] as bool? ?? true;
        store.outputDir = (map['outputDir'] ?? '').toString();
        store.mode = (map['mode'] as num?)?.toInt() ?? 0;
        store.emitJson = map['emitJson'] as bool? ?? true;
        store.emitPng = map['emitPng'] as bool? ?? true;
        store.emitSvg = map['emitSvg'] as bool? ?? false;
        // v4 新增字段：老配置没有这项时按"全中文"处理（保持老用户原有观感）
        store.forceChinese = map['forceChinese'] as bool? ?? true;
        store.language = (map['language'] ?? '').toString();
        store.firstRunSelfCheckDone =
            map['firstRunSelfCheckDone'] as bool? ?? false;
        store.modeChosen = map['modeChosen'] as bool? ?? false;
        // 老配置里若已明确选过语言（非空），视为"已问过"，升级后不再弹窗
        store.languageChosen =
            map['languageChosen'] as bool? ?? store.language.isNotEmpty;
        store.configVersion = (map['configVersion'] as num?)?.toInt() ?? 0;

        // schema 迁移：版本落后时在此补齐新字段默认值。
        // 当前从 v0/v1 → v2：whiteBackground 上面已用 ?? true 兜底，
        // 这里只更新版本号；以后有破坏性变更时在这里加分支。
        if (store.configVersion < currentConfigVersion) {
          store.configVersion = currentConfigVersion;
          needsConfigRewrite = true;
        }
        if (needsConfigRewrite) await store.save();
      }
    } catch (e) {
      // 配置损坏就用默认值，不阻塞启动——但必须留痕，否则用户"设置总是不生效"查不出来
      AppLogger.instance.warn('config', '读取 config.json 失败，使用默认值: $e');
    }
    return store;
  }

  Future<void> save() async {
    try {
      String storedApiKey;
      if (_apiKeyFromEnvironment) {
        // 环境变量优先但不落盘；保存其他设置时保留现存密文。
        storedApiKey = '';
        if (await _file.exists()) {
          try {
            final current = jsonDecode(await _file.readAsString());
            if (current is Map<String, dynamic>) {
              storedApiKey = (current['apiKey'] ?? '').toString();
            }
          } catch (_) {}
        }
      } else {
        storedApiKey = await SecretStore.seal(apiKey);
        if (apiKey.isNotEmpty && storedApiKey.isEmpty) {
          AppLogger.instance.warn(
            'secret',
            'API Key 未能安全加密；本次配置未写入，避免密钥丢失或降级存储',
          );
          return;
        }
      }
      await configDir.create(recursive: true);
      await _file.writeAsString(
        jsonEncode({
          'apiKey': storedApiKey,
          'model': model,
          'renderScriptPath': renderScriptPath,
          'lastDir': lastDir,
          'whiteBackground': whiteBackground,
          'outputDir': outputDir,
          'mode': mode,
          'emitJson': emitJson,
          'emitPng': emitPng,
          'emitSvg': emitSvg,
          'forceChinese': forceChinese,
          'language': language,
          'firstRunSelfCheckDone': firstRunSelfCheckDone,
          'modeChosen': modeChosen,
          'languageChosen': languageChosen,
          'configVersion': configVersion,
        }),
      );
    } catch (e) {
      // 写失败不阻塞使用，但一定要记录：受控环境下 AppData 可能不可写，
      // 表现为"改了设置、重启又变回去"，没有这行日志根本查不出来。
      AppLogger.instance.warn('config', '写入 config.json 失败（设置将不会保存）: $e');
    }
  }

  /// 猜测渲染脚本位置（render_orbat.js）。找不到就让用户在设置里指定。
  ///
  /// 优先级：应用自带 runtime（随软件分发，最稳）→ 开发目录 → 原工作区。
  static Future<String> _guessRenderScript() async {
    final candidates = <String>[];

    // 1) 可执行文件同级的 runtime/（发布版布局）
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir/runtime/render_orbat.js');
    } catch (_) {}

    // 2) 开发时：项目 app/runtime/
    try {
      candidates.add('${Directory.current.path}/runtime/render_orbat.js');
      candidates.add('${Directory.current.path}/app/runtime/render_orbat.js');
    } catch (_) {}

    // （旧版本这里还有"开发机工作区"的候选路径——公开测试版不含本机特征，已删除）

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return candidates.isNotEmpty ? candidates.first : '';
  }
}
