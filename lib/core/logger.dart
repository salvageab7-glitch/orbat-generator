/// 全软件日志系统
///
/// 目标：任何一个环节出问题，都能从日志里还原「当时发生了什么」，
/// 而不是只能看到界面上一句"失败了"。
///
/// 设计要点：
///   · **异步写**：日志进队列，定时批量落盘，不阻塞 UI
///   · **静默降级**：任何写失败都不影响主流程（日志是副产物）
///   · **自动轮转**：单文件 5MB，按天分文件，保留 30 天
///   · **敏感信息过滤**：API Key 只记指纹，不落明文
library;

import 'dart:async';
import 'dart:io';

import '../render/renderer.dart' show resolveWritableDir;

enum LogLevel { debug, info, warn, error }

extension LogLevelX on LogLevel {
  String get label => switch (this) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO ',
        LogLevel.warn => 'WARN ',
        LogLevel.error => 'ERROR',
      };
}

class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int maxFileBytes = 5 * 1024 * 1024;
  static const int keepDays = 30;
  static const int maxSnapshots = 50;

  Directory? _logDir;
  Directory? _snapDir;
  File? _current;
  IOSink? _sink;
  final List<String> _queue = [];
  Timer? _timer;
  bool _disabled = false;
  bool _ready = false;
  int _writtenBytes = 0;
  String? _sessionTag;

  String? get logDirPath => _logDir?.path;
  String? get snapshotDirPath => _snapDir?.path;
  String? get currentLogPath => _current?.path;
  bool get isEnabled => _ready && !_disabled;

  /// 初始化。失败时静默关闭日志，不影响主流程。
  Future<void> init() async {
    if (_current != null || _disabled) return;
    try {
      // 日志要长期保留，优先放固定的应用数据目录，而不是会被系统清理的 Temp
      Directory? base;
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final d = Directory('$appData/OrbatGenerator');
        try {
          if (!d.existsSync()) d.createSync(recursive: true);
          // 写探针确认可写
          final probe = File('${d.path}/.log_probe');
          probe.writeAsStringSync('ok');
          probe.deleteSync();
          base = d;
        } catch (_) {
          base = null;
        }
      }
      base ??= await resolveWritableDir();
      if (base == null) {
        _disabled = true;
        return;
      }

      _logDir = Directory('${base.path}/orbat-logs');
      _snapDir = Directory('${base.path}/orbat-snapshots');
      if (!_logDir!.existsSync()) _logDir!.createSync(recursive: true);
      if (!_snapDir!.existsSync()) _snapDir!.createSync(recursive: true);

      _sessionTag = _stamp();
      _openTodayFile();

      // 每 2 秒批量刷一次
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _flush());

      _cleanupOldLogs();
      _cleanupOldSnapshots();
      _ready = true;

      info('app', '=== 日志系统启动 ===');
      info('app', '日志目录: ${_logDir!.path}');
      info('app', '快照目录: ${_snapDir!.path}');
    } catch (_) {
      _disabled = true;
    }
  }

  void _openTodayFile() {
    try {
      final d = DateTime.now();
      final day = '${d.year}-${_two(d.month)}-${_two(d.day)}';
      final f = File('${_logDir!.path}/app-$day.log');
      _current = f;
      _writtenBytes = f.existsSync() ? f.lengthSync() : 0;
      _sink = f.openWrite(mode: FileMode.append);
    } catch (_) {
      _disabled = true;
    }
  }

  /// 超过单文件上限就换一个分卷文件
  void _rotateIfNeeded() {
    if (_writtenBytes < maxFileBytes) return;
    try {
      _sink?.flush();
      _sink?.close();
      final d = DateTime.now();
      final day = '${d.year}-${_two(d.month)}-${_two(d.day)}';
      final seq = DateTime.now().millisecondsSinceEpoch % 100000;
      _current = File('${_logDir!.path}/app-$day-$seq.log');
      _sink = _current!.openWrite(mode: FileMode.append);
      _writtenBytes = 0;
      _enqueue('WARN  [app] 日志文件达到上限，已切换到 ${_current!.path}');
    } catch (_) {
      _disabled = true;
    }
  }

  void _cleanupOldLogs() {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: keepDays));
      for (final f in _logDir!.listSync()) {
        if (f is! File) continue;
        if (!f.path.endsWith('.log')) continue;
        if (f.lastModifiedSync().isBefore(cutoff)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _cleanupOldSnapshots() {
    try {
      final files = _snapDir!
          .listSync()
          .whereType<File>()
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (var i = maxSnapshots; i < files.length; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ---------- 写入 ----------

  void _enqueue(String line) {
    // 未初始化或已禁用时直接丢弃，避免队列无限堆积
    if (!_ready || _disabled) return;
    _queue.add(line);
    // 队列太长时立即刷，避免内存堆积
    if (_queue.length > 200) _flush();
  }

  void _flush() {
    if (_disabled || _sink == null || _queue.isEmpty) return;
    rotateCheck();
    try {
      final batch = _queue.join('\n');
      _queue.clear();
      _sink!.writeln(batch);
      _writtenBytes += batch.length + 1;
      _sink!.flush();
    } catch (_) {
      _disabled = true;
      _queue.clear();
    }
  }

  void rotateCheck() => _rotateIfNeeded();

  // ---------- 对外 API ----------

  void log(LogLevel level, String tag, String message) {
    if (!_ready || _disabled) return;
    final ts = _stamp(withMs: true);
    final lines = message.split('\n');
    _enqueue('$ts ${level.label} [${_pad(tag)}] ${lines.first}');
    for (final l in lines.skip(1)) {
      _enqueue('$ts ${level.label} [${_pad(tag)}]   $l');
    }
  }

  void debug(String tag, String message) => log(LogLevel.debug, tag, message);
  void info(String tag, String message) => log(LogLevel.info, tag, message);
  void warn(String tag, String message) => log(LogLevel.warn, tag, message);

  void error(String tag, String message, [Object? err, StackTrace? st]) {
    log(LogLevel.error, tag, message);
    if (err != null) log(LogLevel.error, tag, '异常: $err');
    if (st != null) {
      final s = st.toString().split('\n').take(8).join('\n');
      log(LogLevel.error, tag, '栈:\n$s');
    }
  }

  /// 分节标题，便于在长日志里定位一次操作的起点
  void section(String title) {
    if (!_ready || _disabled) return;
    _enqueue('');
    _enqueue('${_stamp(withMs: true)} ------ $title ------');
  }

  // ---------- 快照 ----------

  /// 保存一次生成的 JSON 与 AI 原始输出，便于事后复现
  Future<String?> saveSnapshot(
    String baseName, {
    required String json,
    String? rawAiOutput,
  }) async {
    if (_disabled || _snapDir == null) return null;
    try {
      final safe = baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final stamp = _stamp().replaceAll(':', '-');
      final f = File('${_snapDir!.path}/${stamp}_$safe.json');
      await f.writeAsString(json, flush: true);
      if (rawAiOutput != null && rawAiOutput.isNotEmpty) {
        final r = File('${_snapDir!.path}/${stamp}_$safe.raw.txt');
        await r.writeAsString(rawAiOutput, flush: true);
      }
      info('snapshot', '已保存快照: ${f.path}');
      _cleanupOldSnapshots();
      return f.path;
    } catch (e) {
      warn('snapshot', '保存快照失败: $e');
      return null;
    }
  }

  // ---------- 工具 ----------

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _pad(String tag) => tag.padRight(8);

  static String _stamp({bool withMs = false}) {
    final d = DateTime.now();
    final base = '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
    return withMs ? '$base.${d.millisecond.toString().padLeft(3, '0')}' : base;
  }

  /// API Key 指纹：前 6 位 + 长度，足够区分又不泄露
  static String keyFingerprint(String? key) {
    if (key == null || key.isEmpty) return '(未配置)';
    if (key.length <= 8) return '***';
    return '${key.substring(0, 6)}…(${key.length}位)';
  }

  String? get sessionTag => _sessionTag;

  Future<void> close() async {
    _timer?.cancel();
    _flush();
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }
}
