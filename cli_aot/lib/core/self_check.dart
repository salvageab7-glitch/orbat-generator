/// 本机环境自检
///
/// 只查本地，不发任何 API 请求（不消耗额度）。
/// 目的是回答一个问题：**这台机器现在能不能完整跑完「识图 → 出图」全流程**。
library;

import 'dart:io';

import 'logger.dart';

class CheckItem {
  final String name;
  final bool ok;
  final bool optional;
  final String detail;
  final String? fix;

  const CheckItem({
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
  }) async {
    final items = <CheckItem>[];
    final log = AppLogger.instance;
    log.section('环境自检');

    // ---------- 1. Node.js ----------
    final nodePath = _findNode();
    if (nodePath != null) {
      try {
        final r = await Process.run(nodePath, ['-v']);
        final ver = r.stdout.toString().trim();
        final major = int.tryParse(
                ver.replaceAll('v', '').split('.').first) ??
            0;
        items.add(CheckItem(
          name: 'Node.js',
          ok: major >= 24,
          detail: '$ver  ($nodePath)',
          fix: major >= 24
              ? null
              : '出图脚本要求 Node.js ≥ 24（低版本会静默挂死），当前 $ver',
        ));
      } catch (e) {
        items.add(CheckItem(
          name: 'Node.js',
          ok: false,
          detail: '无法执行: $e',
          fix: '检查 Node.js 安装是否完整',
        ));
      }
    } else {
      items.add(const CheckItem(
        name: 'Node.js',
        ok: false,
        detail: '未找到',
        fix: '安装 Node.js 24 或更高版本（出图依赖它）',
      ));
    }

    // ---------- 2. 浏览器 ----------
    final browsers = _findBrowsers();
    items.add(CheckItem(
      name: '浏览器（出图用）',
      ok: browsers.isNotEmpty,
      detail: browsers.isEmpty ? '未找到 Chrome / Edge' : browsers.join('、'),
      fix: browsers.isEmpty ? '出图需要 Chrome 或 Edge，请安装其一' : null,
    ));

    // ---------- 3. 渲染脚本 ----------
    final script = renderScriptPath?.trim();
    if (script == null || script.isEmpty) {
      // 没配置时，看 exe 同级 runtime 里有没有
      final bundled = _bundledScript();
      items.add(CheckItem(
        name: '渲染脚本',
        ok: bundled != null,
        detail: bundled != null
            ? '使用内置: $bundled'
            : '设置里未指定，且未找到内置脚本',
        fix: bundled != null
            ? null
            : '在设置中指定 render_orbat.js 的路径',
      ));
    } else {
      final f = File(script);
      items.add(CheckItem(
        name: '渲染脚本',
        ok: f.existsSync(),
        detail: script,
        fix: f.existsSync() ? null : '该路径下找不到文件，请重新指定',
      ));
    }

    // ---------- 4. API Key ----------
    final key = apiKey?.trim() ?? '';
    items.add(CheckItem(
      name: 'API Key',
      ok: key.isNotEmpty,
      detail: key.isEmpty ? '未配置' : AppLogger.keyFingerprint(key),
      fix: key.isEmpty ? '在设置里填入 DeepSeek API Key' : null,
    ));

    // ---------- 5. 目录可写 ----------
    final logDir = log.logDirPath;
    final snapDir = log.snapshotDirPath;
    final writable = logDir != null && snapDir != null;
    items.add(CheckItem(
      name: '工作目录',
      ok: writable,
      detail: writable ? '日志/快照目录可写' : '日志系统未初始化',
      fix: writable ? null : '检查磁盘权限，或以管理员身份运行一次',
    ));

    // ---------- 6. 输出目录（编制档案） ----------
    // 这里只检查"当前工作目录是否可写"，因为输出路径由用户在出图时选择
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
      name: '当前目录可写',
      ok: cwdOk,
      detail: cwdDetail,
      fix: cwdOk ? null : '出图会写到这里，请换一个有写权限的位置',
    ));

    // ---------- 7. 网络（可选，不算失败） ----------
    final dsOk = await _tcpReachable('api.deepseek.com', 443);
    items.add(CheckItem(
      name: 'DeepSeek 接口连通',
      ok: dsOk,
      optional: true,
      detail: dsOk ? 'api.deepseek.com:443 可达' : '连接超时或被拦截',
      fix: dsOk ? null : '识图需要联网访问 api.deepseek.com',
    ));

    final saOk = await _tcpReachable('spatialillusions.com', 443);
    items.add(CheckItem(
      name: '渲染站点连通',
      ok: saOk,
      optional: true,
      detail: saOk ? 'spatialillusions.com:443 可达' : '连接超时或被拦截',
      fix: saOk ? null : '出图需要联网访问 spatialillusions.com',
    ));

    for (final i in items) {
      log.info('selfcheck',
          '${i.level.toUpperCase()} ${i.name}: ${i.detail}${i.fix != null ? " | 建议: ${i.fix}" : ""}');
    }

    return SelfCheckResult(items);
  }

  // ---------- 工具 ----------

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
