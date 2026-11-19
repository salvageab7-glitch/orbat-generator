/// 出图模块 —— 调用线上渲染器（spatialillusions.com）产出 SVG / PNG
///
/// 设计原则（沿用工作区硬规则）：
///   1. **PNG 只能由线上版渲染器产出**，不做本地渲染冒充。
///   2. 渲染脚本是经过验证的成熟资产，本模块只负责「找到 node、传参、解析输出」。
///   3. node 主版本必须 ≥ 24：低版本会无界挂起（画布渲染完但进程不退出）。
///
/// 健壮性约定（踩过的坑）：
///   - 目录写权限**不可假设**。系统 Temp、%APPDATA% 都可能拒绝访问，
///     所以一律先探测再使用，失败就降级，绝不因此抛未捕获异常。
///   - 日志是"尽力而为"的副产物，写不了也不能影响出图。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 出图结果
class RenderResult {
  final bool ok;
  final String? svgPath;
  final String? pngPath;
  final String? error;
  final Duration elapsed;
  final String? logPath;

  RenderResult({
    required this.ok,
    this.svgPath,
    this.pngPath,
    this.error,
    required this.elapsed,
    this.logPath,
  });

  @override
  String toString() => ok
      ? 'RenderResult(ok, png=$pngPath, ${elapsed.inSeconds}s)'
      : 'RenderResult(failed: $error)';
}

/// 渲染器配置
class RendererConfig {
  /// 渲染脚本绝对路径（render_orbat.js）
  final String scriptPath;

  /// node 可执行文件路径；null 表示自动探测
  final String? nodePath;

  /// 输出倍率（默认 2 = 2x 高清）
  final int scale;

  /// PNG 是否用白色背景。false = 透明底（方便用户叠自己的背景图）
  final bool whiteBackground;

  /// 整体超时。
  ///
  /// 脚本内部最坏路径约为：启动浏览器 40s + 等站点初始化 120s + 导入重试 90s
  /// + 截图 5s ≈ 255s，所以给足 5 分钟，避免脚本还在正常等待时被误杀。
  final Duration timeout;

  const RendererConfig({
    required this.scriptPath,
    this.nodePath,
    this.scale = 2,
    this.whiteBackground = true,
    this.timeout = const Duration(minutes: 5),
  });
}

/// 应用数据目录：%APPDATA%\OrbatGenerator（Windows）/ ~/.config/orbat（其他）
Directory get appDataDir {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return Directory('$appData/OrbatGenerator');
    }
  }
  // 安卓：systemTemp = <数据根>/cache，反推数据根落 files/（稳定，code_cache 会被清理）
  if (Platform.isAndroid) {
    try {
      final dataRoot = Directory(Directory.systemTemp.path).parent.path;
      return Directory('$dataRoot/files/OrbatGenerator');
    } catch (_) {}
  }
  final home = Platform.environment['HOME'] ?? '.';
  return Directory('$home/.config/orbat');
}

/// 找一个**确实可写**的目录。
///
/// 按「系统临时目录 → 应用数据目录 → 当前目录 → exe 同级」依次试写探针。
/// 全部不可写时返回 null（调用方据此给出明确提示，而不是崩溃）。
Future<Directory?> resolveWritableDir() async {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final androidFirst = Platform.isAndroid; // 安卓：files/ 优先于 code_cache
  final candidates = <String>[
    if (androidFirst) '${appDataDir.path}/tmp',
    Directory.systemTemp.path,
    if (!androidFirst) '${appDataDir.path}/tmp',
    Directory.current.path,
    '$exeDir/tmp',
  ];

  for (final c in candidates) {
    try {
      final d = Directory(c);
      if (!d.existsSync()) await d.create(recursive: true);
      // 写探针确认真的有写权限（exists 不代表可写）
      final probe =
          File('${d.path}/.orbat_probe_${DateTime.now().microsecondsSinceEpoch}');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return d;
    } catch (_) {
      // 换下一个候选
    }
  }
  return null;
}

/// 渲染器
class OrbatRenderer {
  final RendererConfig config;

  OrbatRenderer(this.config);

  /// 探测系统 node（要求 ≥ 24）。返回 null 表示没找到合格版本。
  static Future<String?> findNode() async {
    // 常见安装位置优先——Windows 上 winget/msi 默认装这里，
    // 而 PATH 上的 node 可能是被其他工具管理的旧版本。
    String? bundled;
    try {
      // 完整版安装器/便携包随带的 node.exe（exe 同级 bin\），优先于系统安装
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final p = '$exeDir\\bin\\node.exe';
      if (File(p).existsSync()) bundled = p;
    } catch (_) {}
    final candidates = <String>[
      if (bundled != null) bundled,
      r'C:\Program Files\nodejs\node.exe',
      r'C:\Program Files (x86)\nodejs\node.exe',
      'node', // 最后退回 PATH
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c, ['--version']);
        if (r.exitCode != 0) continue;
        final v = (r.stdout as String).trim(); // 形如 v24.19.0
        final major = int.tryParse(v.replaceFirst('v', '').split('.').first);
        if (major != null && major >= 24) return c;
      } catch (_) {
        // 该候选不存在，继续
      }
    }
    return null;
  }

  /// 执行渲染。
  ///
  /// [normalizedJson] 必须是 7 键归一化后的完整树（含根 commandLevels）。
  /// [outputBase] 输出基名（不含扩展名），会产出 `.svg` 与 `.png`。
  /// [onLog] 每收到脚本的一行输出就回调一次，供界面显示实时进度。
  Future<RenderResult> render({
    required String normalizedJson,
    required String outputBase,
    void Function(String line)? onLog,
  }) async {
    final sw = Stopwatch()..start();

    // ---- 日志：尽力而为，写不了不阻塞 ----
    File? logFile;
    Directory? workBase;

    void writeLog(String line) {
      final f = logFile;
      if (f == null) return;
      try {
        f.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
      } catch (_) {
        logFile = null; // 一旦写失败就彻底放弃，避免拖慢后续步骤
      }
    }

    void log(String line) {
      onLog?.call(line);
      writeLog(line);
    }

    RenderResult finish({
      required bool ok,
      String? png,
      String? svg,
      String? error,
    }) {
      return RenderResult(
        ok: ok,
        pngPath: png,
        svgPath: svg,
        error: error,
        elapsed: sw.elapsed,
        logPath: logFile?.path,
      );
    }

    // ---- 1) 可写目录 ----
    workBase = await resolveWritableDir();
    if (workBase == null) {
      return finish(
        ok: false,
        error: '找不到可写的目录（系统临时目录、应用数据目录、程序目录都不可写）。'
            '出图需要在本地写临时文件，请检查磁盘权限或安全软件的拦截设置。',
      );
    }

    // 日志放在可写目录下（不与 APPDATA 的权限绑定）
    try {
      final logDir = Directory('${workBase.path}/orbat-logs');
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final f = File('${logDir.path}/render-$stamp.log');
      f.writeAsStringSync(''); // 试写，失败则整个日志功能放弃
      logFile = f;
    } catch (_) {
      logFile = null;
    }

    log('[client] 出图开始，输出基名: $outputBase');
    log('[client] 工作目录: ${workBase.path}');

    // ---- 2) 运行环境 ----
    final node = config.nodePath ?? await findNode();
    if (node == null) {
      return finish(
        ok: false,
        error: '未找到 node ≥ 24。请安装 Node.js 24+ 后重试（低版本会无界挂起）。',
      );
    }
    log('[client] 使用 node: $node');

    if (!File(config.scriptPath).existsSync()) {
      return finish(ok: false, error: '渲染脚本不存在: ${config.scriptPath}');
    }
    log('[client] 渲染脚本: ${config.scriptPath}');

    // ---- 3) 输出目录：必须真的可写，否则后面写 SVG 才报 EPERM，提示很不友好 ----
    Directory? outParent;
    try {
      outParent = Directory(outputBase).parent;
      if (!outParent.existsSync()) {
        await outParent.create(recursive: true);
        log('[client] 已创建输出目录: ${outParent.path}');
      }
      final probe = File('${outParent.path}/.orbat_out_probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } catch (e) {
      log('[client] 输出目录不可写: $e');
      return finish(
        ok: false,
        error: '输出目录不可写：${outParent?.path ?? outputBase}\n'
            '请换一个保存位置（例如桌面），或在设置里指定一个可写目录。',
      );
    }
    log('[client] 输出目录可写: ${outParent.path}');

    // ---- 4) 写输入 + 起子进程 ----
    Directory? tmpDir;
    try {
      try {
        tmpDir = await workBase.createTemp('orbat_input_');
      } catch (e) {
        log('[client] 创建临时目录失败: $e');
        return finish(ok: false, error: '创建临时目录失败：$e');
      }

      final inputFile = File('${tmpDir.path}/input.json');
      await inputFile.writeAsString(normalizedJson, encoding: utf8);
      log('[client] 输入 JSON ${normalizedJson.length} 字符');

      final process = await Process.start(
        node,
        [config.scriptPath, inputFile.path, outputBase],
        environment: {
          'SCALE': '${config.scale}',
          // 白色背景开关：0 = 透明底 PNG
          'ORBAT_WHITE_BG': config.whiteBackground ? '1' : '0',
          // 把验证过可写的目录传给脚本，避免它自己用 os.tmpdir() 踩坑
          'ORBAT_WORK_DIR': workBase.path,
        },
      );
      log('[client] 子进程已启动 pid=${process.pid}');

      // 逐行转发输出，界面实时可见
      final outBuf = StringBuffer();
      final errBuf = StringBuffer();

      final outDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        outBuf.writeln(line);
        log(line);
      }).asFuture<void>().catchError((Object e) {
        log('[client] stdout 读取中断: $e');
      });

      final errDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        errBuf.writeln(line);
        log('[stderr] $line');
      }).asFuture<void>().catchError((Object e) {
        log('[client] stderr 读取中断: $e');
      });

      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(config.timeout);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        return finish(
          ok: false,
          error: '渲染超时（${config.timeout.inSeconds}s）。'
              '看最后停在哪个阶段：「等待站点初始化」通常是网络无法访问'
              ' spatialillusions.com；「启动浏览器」则是本机 Chrome 起不来。',
        );
      }
      await Future.wait([outDone, errDone]);
      log('[client] 子进程退出，exitCode=$exitCode');

      final stdout = outBuf.toString();
      final stderr = errBuf.toString();

      if (exitCode != 0) {
        final envHint = _envHint(stderr);
        final head = envHint ??
            (exitCode == 2 ? 'Node.js 版本不符（需 ≥ 24）' : '请查看下方日志定位原因');
        return finish(
          ok: false,
          error: '渲染失败（退出码 $exitCode）：$head\n${_tail(stderr)}\n${_tail(stdout)}',
        );
      }

      // ---- 5) 解析产物 ----
      final svg = RegExp(r'^SVG_FILE (.+?\.svg)', multiLine: true)
          .firstMatch(stdout)
          ?.group(1)
          ?.trim();
      // 路径可能含空格（根节点名如「2nd Division(New South Wales)」会进入文件名），
      // 用 \S+ 会在空格处截断，导致误判"PNG 未生成"。匹配到 .png 结尾为止。
      final png = RegExp(r'^PNG_FILE (.+?\.png)', multiLine: true)
          .firstMatch(stdout)
          ?.group(1)
          ?.trim();

      if (png == null) {
        return finish(
          ok: false,
          error: '脚本未返回 PNG 路径，输出如下：\n${_tail(stdout)}',
        );
      }

      final pngFile = File(png);
      if (!pngFile.existsSync() || pngFile.lengthSync() == 0) {
        return finish(ok: false, error: 'PNG 未生成或为空: $png');
      }
      log('[client] PNG 已生成 ${(pngFile.lengthSync() / 1024).toStringAsFixed(0)} KB');

      return finish(ok: true, png: png, svg: svg);
    } catch (e, st) {
      log('[client] 异常: $e');
      writeLog(st.toString());
      return finish(ok: false, error: '出图异常：$e');
    } finally {
      // 清理临时输入（失败无所谓）
      try {
        await tmpDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 只取输出末尾若干行，避免把几百行 glyph 警告塞进错误信息
  static String _tail(String s, {int lines = 8}) {
    final all = s.trim().split('\n');
    if (all.length <= lines) return s.trim();
    return '...\n${all.sublist(all.length - lines).join('\n')}';
  }

  /// 从渲染脚本的 stderr 识别常见环境问题，翻译成用户能照着做的指引。
  /// 命中就返回一句指引；未命中返回 null（保持原始日志）。
  static String? _envHint(String stderr) {
    if (stderr.contains('未找到 Chromium 系浏览器')) {
      return '缺少浏览器：请确认已安装 Chrome 或 Edge（Windows 10/11 一般自带 Edge），'
          '装好后重启本软件再出图。';
    }
    if (stderr.contains('FATAL: 出图必须用 node') || stderr.contains('node ≥ 24')) {
      return 'Node.js 未安装或版本过低：请到 nodejs.org 安装 LTS 版（≥ 24），'
          '装完后重启本软件再出图。';
    }
    if (stderr.contains('浏览器调试端口') || stderr.contains('ECONNREFUSED')) {
      return '浏览器启动失败：可能是安全软件拦截了无头浏览器，'
          '请把本软件和浏览器加入白名单后重试。';
    }
    if (stderr.contains('ERR_NAME_NOT_RESOLVED') ||
        stderr.contains('ERR_INTERNET') ||
        stderr.contains('ERR_TIMED_OUT')) {
      return '网络访问失败：出图需要能打开 spatialillusions.com，'
          '请检查网络或代理设置后重试。';
    }
    return null;
  }
}
