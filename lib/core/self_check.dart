/// 本机环境自检
///
/// 只查本地，不发任何 API 请求（不消耗额度）。
/// 目的是回答一个问题：**这台机器现在能不能完整跑完「识图 → 出图」全流程**。
library;

import 'dart:convert';
import 'dart:io';

import '../i18n/l10n.dart';
import 'logger.dart';

class CheckItem {
  final String name;
  final bool ok;
  final bool optional;
  final String detail;
  final String? fix;

  CheckItem({
    required this.name,
    required this.ok,
    required this.detail,
    this.optional = false,
    this.fix,
  });

  String get level => ok ? 'ok' : (optional ? 'warn' : 'fail');
}

class SelfCheckResult {
  final List<CheckItem> items;

  const SelfCheckResult(this.items);

  bool get allOk => items.where((i) => !i.optional).every((i) => i.ok);
  int get failCount => items.where((i) => !i.ok && !i.optional).length;
  int get warnCount => items.where((i) => !i.ok && i.optional).length;
}

class SelfCheck {
  /// [renderScriptPath] 用户在设置里配置的渲染脚本路径
  /// [apiKey] 当前的 API Key（只判断是否为空，不发请求）
  static Future<SelfCheckResult> run({
    String? renderScriptPath,
    String? apiKey,
    String? apiBaseUrl,
    bool smokeRender = false,
    String? outputDir,
    int? mode,
    Future<CheckItem> Function()? androidSmoke,
  }) async {
    final items = <CheckItem>[];
    final log = AppLogger.instance;
    log.section('环境自检');
    // 安卓端：出图走内置 WebView 线上渲染，Node/浏览器/渲染脚本三项均不适用
    final isAndroid = Platform.isAndroid;
    String? nodePath; // Windows 分支填充，冒烟用
    String? script; // Windows 分支填充，冒烟用

    // ---------- 1. Node.js ----------
    if (isAndroid) {
      items.add(CheckItem(
        name: tr('Node.js'),
        ok: true,
        detail: tr('安卓端不需要（出图走内置 WebView）'),
      ));
    } else {
      nodePath = _findNode();
      if (nodePath != null) {
        try {
          final r = await Process.run(nodePath, ['-v']);
          final ver = r.stdout.toString().trim();
          final major =
              int.tryParse(ver.replaceAll('v', '').split('.').first) ?? 0;
          items.add(CheckItem(
            name: tr('Node.js'),
            ok: major >= 24,
            detail: '$ver  ($nodePath)',
            fix: major >= 24 ? null : '出图脚本要求 Node.js ≥ 24（低版本会静默挂死），当前 $ver',
          ));
        } catch (e) {
          items.add(CheckItem(
            name: tr('Node.js'),
            ok: false,
            detail: '无法执行: $e',
            fix: tr('检查 Node.js 安装是否完整'),
          ));
        }
      } else {
        items.add(CheckItem(
          name: tr('Node.js'),
          ok: false,
          detail: tr('未找到'),
          fix: tr('安装 Node.js 24 或更高版本（出图依赖它）'),
        ));
      }
    }

    // ---------- 2. 浏览器 ----------
    if (isAndroid) {
      items.add(CheckItem(
        name: tr('浏览器（出图用）'),
        ok: true,
        detail: tr('安卓端使用内置 WebView'),
      ));
    } else {
      final browsers = _findBrowsers();
      items.add(CheckItem(
        name: tr('浏览器（出图用）'),
        ok: browsers.isNotEmpty,
        detail: browsers.isEmpty ? '未找到 Chrome / Edge' : browsers.join('、'),
        fix: browsers.isEmpty ? '出图需要 Chrome 或 Edge，请安装其一' : null,
      ));
    }

    // ---------- 3. 渲染脚本 ----------
    if (isAndroid) {
      items.add(CheckItem(
        name: tr('渲染脚本'),
        ok: true,
        detail: tr('安卓端不需要（出图走内置 WebView）'),
      ));
    } else {
      script = renderScriptPath?.trim();
      if (script == null || script.isEmpty) {
        // 没配置时，看 exe 同级 runtime 里有没有
        final bundled = _bundledScript();
        items.add(CheckItem(
          name: tr('渲染脚本'),
          ok: bundled != null,
          detail: bundled != null ? '使用内置: $bundled' : '设置里未指定，且未找到内置脚本',
          fix: bundled != null ? null : '在设置中指定 render_orbat.js 的路径',
        ));
      } else {
        final f = File(script);
        items.add(CheckItem(
          name: tr('渲染脚本'),
          ok: f.existsSync(),
          detail: script,
          fix: f.existsSync() ? null : '该路径下找不到文件，请重新指定',
        ));
      }
    }

    // ---------- 4. API Key ----------
    // 模式三（Agent 全权）不需要软件 API：列为可选提示而非失败项
    final key = apiKey?.trim() ?? '';
    final keyOptional = mode == 2 || isAndroid && mode == null;
    items.add(CheckItem(
      name: tr('API Key'),
      ok: key.isNotEmpty,
      optional: keyOptional,
      detail: key.isEmpty
          ? (keyOptional ? '未配置（当前模式不需要）' : '未配置')
          : AppLogger.keyFingerprint(key),
      fix: key.isEmpty && !keyOptional ? '在设置里填入 API Key' : null,
    ));

    // ---------- 5. 目录可写 ----------
    final logDir = log.logDirPath;
    final snapDir = log.snapshotDirPath;
    final writable = logDir != null && snapDir != null;
    items.add(CheckItem(
      name: tr('工作目录'),
      ok: writable,
      detail: writable ? tr('日志/快照目录可写') : tr('日志系统未初始化'),
      fix: writable ? null : '检查磁盘权限，或以管理员身份运行一次',
    ));

    // ---------- 6. 输出目录（编制档案） ----------
    // Windows：检查"当前工作目录是否可写"（输出路径由用户在出图时选择）
    // 安卓：Directory.current 是 / 永远不可写，改查实际使用的输出归档目录
    if (isAndroid) {
      final target = (outputDir ?? '').trim().isEmpty
          ? Directory.systemTemp.path
          : outputDir!.trim();
      var outOk = true;
      var outDetail = target;
      try {
        final d = Directory(target);
        if (!d.existsSync()) d.createSync(recursive: true);
        final probe = File('${d.path}${Platform.pathSeparator}.write_probe');
        probe.writeAsStringSync('ok');
        probe.deleteSync();
        outDetail = tr('产物输出目录可写');
      } catch (_) {
        outOk = false;
        outDetail = '$target（不可写）';
      }
      items.add(CheckItem(
        name: tr('输出目录可写'),
        ok: outOk,
        detail: outDetail,
        fix: outOk ? null : '在设置里更换输出目录，或清理存储空间后重试',
      ));
    } else {
      var cwdOk = true;
      String cwdDetail = Directory.current.path;
      try {
        final probe = File(
            '${Directory.current.path}${Platform.pathSeparator}.write_probe');
        probe.writeAsStringSync('ok');
        probe.deleteSync();
      } catch (_) {
        cwdOk = false;
        cwdDetail = '${Directory.current.path}（不可写）';
      }
      items.add(CheckItem(
        name: tr('当前目录可写'),
        ok: cwdOk,
        detail: cwdDetail,
        fix: cwdOk ? null : '出图会写到这里，请换一个有写权限的位置',
      ));
    }

    // ---------- 7. 网络（可选，不算失败） ----------
    final Uri? apiUri = Uri.tryParse((apiBaseUrl ?? '').trim());
    final String apiHost =
        (apiUri?.host.isNotEmpty ?? false) ? apiUri!.host : 'api.deepseek.com';
    final int apiPort = apiUri?.hasPort == true
        ? apiUri!.port
        : (apiUri?.scheme == 'http' ? 80 : 443);
    final dsOk = await _tcpReachable(apiHost, apiPort);
    items.add(CheckItem(
      name: tr('AI 接口连通'),
      ok: dsOk,
      optional: true,
      detail: dsOk ? '$apiHost:$apiPort 可达' : '连接超时或被拦截',
      fix: dsOk ? null : '识图需要联网访问 $apiHost',
    ));

    final saOk = await _tcpReachable('spatialillusions.com', 443);
    items.add(CheckItem(
      name: tr('渲染站点连通'),
      ok: saOk,
      optional: true,
      detail: saOk ? 'spatialillusions.com:443 可达' : '连接超时或被拦截',
      fix: saOk ? null : '出图需要联网访问 spatialillusions.com',
    ));

    // ---------- 8. 出图冒烟（可选，真跑一次 3 节点渲染） ----------
    // 前面几项全是"存在性检查"：浏览器装了、域名通、脚本在。
    // 但站点改版、浏览器被策略禁用、node 版本不兼容，都会让这些检查全绿却出不了图。
    // 这一项用内置的 3 节点固定 JSON 真渲染一次，把"能不能出图"变成确定性结论。
    if (smokeRender) {
      items.add(await _smokeRender(
          nodePath: isAndroid ? null : nodePath,
          script: isAndroid ? null : (script ?? _bundledScript()),
          androidSmoke: androidSmoke));
    }

    for (final i in items) {
      log.info('selfcheck',
          '${i.level.toUpperCase()} ${i.name}: ${i.detail}${i.fix != null ? " | 建议: ${i.fix}" : ""}');
    }

    return SelfCheckResult(items);
  }

  // ---------- 工具 ----------

  /// 微型出图冒烟：3 个节点的固定 JSON → 调渲染脚本 → 检查 PNG 真的产出了。
  ///
  /// 只用本地脚本与线上站点，不消耗任何 API 额度。
  /// 失败原因分三类写进 detail，用户一看就知道该修哪里：
  ///   脚本/Node 环境 → 出图脚本本身跑不起来
  ///   站点未就绪     → 网络到不了或站点改版
  ///   产物为空       → 渲染没报错但没画出东西（最隐蔽的一种）
  static Future<CheckItem> _smokeRender({
    required String? nodePath,
    required String? script,
    Future<CheckItem> Function()? androidSmoke,
  }) async {
    final name = tr('出图冒烟（真渲染一次）');
    // 安卓端：由 UI 层用内置样例 JSON + 隐藏 WebView 执行，自检本身不持有 UI。
    if (Platform.isAndroid) {
      if (androidSmoke != null) return androidSmoke();
      return CheckItem(
        name: name,
        ok: true,
        detail: tr('安卓端跳过（出图在首次使用时验证）'),
        optional: true,
      );
    }
    if (nodePath == null) {
      return CheckItem(
        name: name,
        ok: false,
        detail: tr('跳过：没找到 Node.js'),
        fix: tr('先解决 Node.js，再跑自检'),
        optional: true,
      );
    }
    if (script == null || !File(script).existsSync()) {
      return CheckItem(
        name: name,
        ok: false,
        detail: tr('跳过：找不到 render_orbat.js'),
        fix: tr('在设置里指定渲染脚本路径'),
        optional: true,
      );
    }

    Directory? tmp;
    final sw = Stopwatch()..start();
    try {
      tmp = _makeWorkDir();
      final jsonPath = '${tmp.path}${Platform.pathSeparator}smoke.json';
      final outBase = '${tmp.path}${Platform.pathSeparator}smoke_out';
      // 3 节点固定用例：师部 + 机步营 + 炮兵连，覆盖陆地符号与修饰位。
      // 必须带齐渲染器要求的 7 个 options 键——站点导入器缺键会静默不画
      // （实测漏 dashed/showMapLabels 时，SVG 画布一直空到超时）。
      Map<String, dynamic> node(String name, String sidc,
              [List<Map<String, dynamic>> kids = const []]) =>
          {
            'options': {
              'sidc': sidc,
              'uniqueDesignation': name,
              'additionalInformation': '',
              'dashed': false,
              'outline': false,
              'plain-text-mode': false,
              'showMapLabels': true,
            },
            'subOrganizations': kids,
          };
      // 名称必须短：站点对长标签会换行/截断，而渲染脚本靠"SVG 里出现根名"
      // 判断导入成功——长名会让这个判定永远失败（实测 'Smoke Test Division' 必挂，
      // 换成 'Smoke Div' 立刻通过）。生产侧靠 _adaptNameForRenderer 压长度兜底。
      final smokeMap = node('Smoke Div', '130310002111000000000000000000', [
        node('1st Bn', '130310001612110000000000000000'),
        node('Arty Coy', '130310001513030000000000000000'),
      ]);
      smokeMap['commandLevels'] = '1';
      final smokeJson = const JsonEncoder.withIndent('  ').convert(smokeMap);
      File(jsonPath).writeAsStringSync(smokeJson);

      final r = await Process.run(
        nodePath,
        [script, jsonPath, outBase],
        environment: {
          'ORBAT_WORK_DIR': tmp.path,
          'SCALE': '1',
          'RENDER_PORT': '9426',
        },
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      ).timeout(const Duration(seconds: 150));

      final png = File('$outBase.png');
      final ms = sw.elapsedMilliseconds;
      if (r.exitCode != 0 || !png.existsSync()) {
        final tail = '${r.stdout}\n${r.stderr}'.trim();
        final hint = tail.contains('站点初始化')
            ? '渲染站点未就绪（网络或站点改版）'
            : (tail.contains('FATAL') ? '出图脚本环境不满足（Node 版本等）' : '渲染脚本报错');
        return CheckItem(
          name: name,
          ok: false,
          detail: '失败（${ms}ms）：$hint',
          fix: '详情见日志 selfcheck/smoke 段：${_tail(tail, 300)}',
        );
      }
      final size = png.lengthSync();
      if (size < 1000) {
        return CheckItem(
          name: name,
          ok: false,
          detail: tf('产物过小（{n}B），渲染可能没画出内容', {'n': size}),
          fix: tr('先用界面上的「出图」手动试一张，再看日志'),
        );
      }
      return CheckItem(
        name: name,
        ok: true,
        detail: tf('{ms}ms 出图成功，PNG {kb}KB',
            {'ms': ms, 'kb': (size / 1024).toStringAsFixed(0)}),
      );
    } catch (e) {
      return CheckItem(
        name: name,
        ok: false,
        detail: '异常：$e',
        fix: tr('检查网络与 Node 环境；命令行手动跑 render_orbat.js 可看到完整报错'),
      );
    } finally {
      AppLogger.instance
          .info('selfcheck', 'smoke: ${sw.elapsedMilliseconds}ms');
      try {
        for (final e in tmp?.listSync() ?? const <FileSystemEntity>[]) {
          try {
            e.deleteSync(recursive: true);
          } catch (_) {
            // 浏览器 profile 有时还占着句柄，留着下次覆盖
          }
        }
      } catch (_) {}
    }
  }

  /// 找一个**确实可写**的临时目录。
  ///
  /// 不能直接用 systemTemp：本机（以及部分企业的受控环境）对新 exe 限制写外部目录，
  /// 会报 errno 5；安装版装进 Program Files 时同理。所以按
  /// 系统临时 → 当前目录 → exe 同级 tmp 依次试写，全失败才抛错。
  static Directory _makeWorkDir() {
    final candidates = <String>[
      Directory.systemTemp.path,
      Directory.current.path,
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}tmp',
    ];
    for (final base in candidates) {
      try {
        // 固定目录名（不带时间戳）：自检每次启动都跑，带时间戳会在失败时
        // 攒下一堆 15MB 的浏览器 profile（实测 Chrome 句柄释放慢，删不干净）
        final d = Directory('$base${Platform.pathSeparator}orbat_smoke');
        if (d.existsSync()) {
          for (final e in d.listSync()) {
            try {
              e.deleteSync(recursive: true);
            } catch (_) {
              // 旧的删不掉不影响本次（文件名固定，会被覆盖）
            }
          }
        }
        d.createSync(recursive: true);
        final probe = File('${d.path}${Platform.pathSeparator}.probe');
        probe.writeAsStringSync('ok');
        probe.deleteSync();
        return d;
      } catch (_) {
        // 换下一个候选
      }
    }
    throw const FileSystemException('找不到可写的临时目录（系统临时/当前目录/exe同级均不可写）');
  }

  static String _tail(String s, int max) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '…${t.substring(t.length - max)}';
  }

  static String? _findNode() {
    const candidates = [
      r'C:\Program Files\nodejs\node.exe',
      r'C:\Program Files (x86)\nodejs\node.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    // PATH 里找
    try {
      final r = Process.runSync('where', ['node']);
      if (r.exitCode == 0) {
        final first = r.stdout.toString().trim().split('\n').first.trim();
        if (first.isNotEmpty && File(first).existsSync()) return first;
      }
    } catch (_) {}
    return null;
  }

  static List<String> _findBrowsers() {
    const candidates = [
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    ];
    final out = <String>[];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        out.add(c.contains('chrome') ? 'Chrome' : 'Edge');
      }
    }
    return out.toSet().toList();
  }

  static String? _bundledScript() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final p = '${exeDir.path}${Platform.pathSeparator}runtime'
          '${Platform.pathSeparator}render_orbat.js';
      if (File(p).existsSync()) return p;
      // 开发环境：从项目目录找
      final dev = '${Directory.current.path}${Platform.pathSeparator}runtime'
          '${Platform.pathSeparator}render_orbat.js';
      if (File(dev).existsSync()) return dev;
    } catch (_) {}
    return null;
  }

  static Future<bool> _tcpReachable(String host, int port,
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
