/// 配置存储 —— API Key、渲染脚本路径、上次使用的目录
///
/// 带 schema 版本号：配置文件结构变化时能识别并迁移，不丢用户已有设置。
///
/// M1 用「本地文件 + 机器绑定混淆」存放，避免明文躺着。
/// 注意：混淆不等于加密，只防肉眼直读。后续可无缝换成 Windows DPAPI
/// （flutter_secure_storage），只需替换本文件实现，UI 不用改。
library;

import 'dart:convert';
import 'dart:io';

class SettingsStore {
  static const _obfuscKey = 'orbat-gen-v1';

  /// 配置文件 schema 版本。新增字段/改语义时递增，并在 _migrate 里写迁移逻辑。
  static const int currentConfigVersion = 3;

  /// 已知模型预设（id → 显示名）。可自由填写不在列表里的模型 id。
  static const Map<String, String> knownModels = {
    'deepseek-flash': 'DeepSeek Flash（快，推荐）',
    'deepseek-chat': 'DeepSeek Chat（稳）',
    'deepseek-reasoner': 'DeepSeek Reasoner（推理强，慢）',
  };

  String apiKey;
  String model;
  String renderScriptPath;
  String lastDir;

  /// PNG 是否白底（false = 透明底，方便叠自定义背景图）
  bool whiteBackground;

  /// 输出目录（空 = GUI 用桌面；CLI 用输入目录）。
  /// 用户可通过「更改目录」按钮设置，持久化到 config.json。
  String outputDir;

  /// 工作模式：0=纯软件 1=混合(软件+CLI) 2=插件(Agent全权)
  /// 默认 0（纯软件模式）
  int mode;

  /// 产物开关：出图时输出哪些文件
  bool emitJson;
  bool emitPng;
  bool emitSvg;

  /// 配置文件的 schema 版本（0 表示老版本、还没打版本号）
  int configVersion;

  SettingsStore({
    this.apiKey = '',
    this.model = 'deepseek-flash',
    this.renderScriptPath = '',
    this.lastDir = '',
    this.whiteBackground = true,
    this.outputDir = '',
    this.mode = 0,
    this.emitJson = true,
    this.emitPng = true,
    this.emitSvg = false,
    this.configVersion = currentConfigVersion,
  });

  /// 配置文件目录：%APPDATA%\OrbatGenerator（Windows）/ ~/.config/orbat（其他）
  static Directory get configDir {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory('$appData/OrbatGenerator');
      }
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
    if (envKey.trim().isNotEmpty) store.apiKey = envKey.trim();
    try {
      if (await _file.exists()) {
        final map = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        // 仅当环境变量没提供 key 时才用配置文件里的
        if (store.apiKey.isEmpty) {
          store.apiKey = _deobfuscate((map['apiKey'] ?? '').toString());
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
        store.configVersion = (map['configVersion'] as num?)?.toInt() ?? 0;

        // schema 迁移：版本落后时在此补齐新字段默认值。
        // 当前从 v0/v1 → v2：whiteBackground 上面已用 ?? true 兜底，
        // 这里只更新版本号；以后有破坏性变更时在这里加分支。
        if (store.configVersion < currentConfigVersion) {
          store.configVersion = currentConfigVersion;
          await store.save();
        }
      }
    } catch (_) {
      // 配置损坏就用默认值，不阻塞启动
    }
    return store;
  }

  Future<void> save() async {
    try {
      await configDir.create(recursive: true);
      await _file.writeAsString(jsonEncode({
        'apiKey': _obfuscate(apiKey),
        'model': model,
        'renderScriptPath': renderScriptPath,
        'lastDir': lastDir,
        'whiteBackground': whiteBackground,
        'outputDir': outputDir,
        'mode': mode,
        'emitJson': emitJson,
        'emitPng': emitPng,
        'emitSvg': emitSvg,
        'configVersion': configVersion,
      }));
    } catch (_) {
      // 写失败不阻塞使用
    }
  }

  /// 简单混淆：XOR + base64。目的只是防肉眼直读，不是真加密。
  static String _obfuscate(String s) {
    if (s.isEmpty) return '';
    final bytes = utf8.encode(s);
    final key = utf8.encode(_obfuscKey);
    final out = List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
    return base64.encode(out);
  }

  static String _deobfuscate(String s) {
    if (s.isEmpty) return '';
    try {
      final bytes = base64.decode(s);
      final key = utf8.encode(_obfuscKey);
      final out = List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
      return utf8.decode(out);
    } catch (_) {
      return '';
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
