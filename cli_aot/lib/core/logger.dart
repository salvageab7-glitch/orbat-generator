/// 全软件日志系统
///
/// 目标：任何一个环节出问题，都能从日志里还原「当时发生了什么」，
/// 而不是只能看到界面上一句"失败了"。
///
/// 设计要点：
///   · **异步写**：日志进队列，定时批量落盘，不阻塞 UI
///   · **静默降级**：任何写失败都不影响主流程（日志是副产物）
///   · **自动轮转**：单文件 5MB，按天分文件，正常日志保留 14 天
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

  /// 正常运行日志保留天数（错误报告另存，不参与自动删除）。
  static const int keepDays = 14;
  static const int maxSnapshots = 50;

  Directory? _logDir;
  Directory? _snapDir;
  Directory? _errorDir;
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
  String? get errorReportDirPath => _errorDir?.path;
  String? get currentLogPath => _current?.path;
  bool get isEnabled => _ready && !_disabled;

  /// 读取正常日志尾部（含尚未落盘的队列），供诊断/错误报告使用。
  String readTail({int maxLines = 80}) => _readLogTail(maxLines: maxLines);

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
      _errorDir = Directory('${base.path}/orbat-error-reports');
      if (!_logDir!.existsSync()) _logDir!.createSync(recursive: true);
      if (!_snapDir!.existsSync()) _snapDir!.createSync(recursive: true);
      if (!_errorDir!.existsSync()) _errorDir!.createSync(recursive: true);

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
      final files = _snapDir!.listSync().whereType<File>().toList()
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
      // 不在每次批量写后调用 flush()：IOSink 会自行合并写入；
      // 重复 flush 可能与退出时的 close() 冲突（StreamSink is bound to a stream）。
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

  // ---------- 错误报告（与正常日志分开存储，不自动删除） ----------

  /// 写一份独立错误报告；正常日志仍保留完整上下文。
  Future<String?> saveErrorReport(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) async {
    if (_errorDir == null) return null;
    try {
      final File f = _errorReportFile(tag);
      // 先取日志尾部（含尚在队列里的本次错误行），再冲刷队列。
      final String text =
          _errorReportText(tag, message, error: error, stack: stack);
      _flush();
      await f.writeAsString(text, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// CLI 同步版本：失败信息要在 stdout JSON 返回前落盘。
  String? saveErrorReportSync(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (_errorDir == null) return null;
    try {
      final File f = _errorReportFile(tag);
      final String text =
          _errorReportText(tag, message, error: error, stack: stack);
      _flush();
      f.writeAsStringSync(text, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  File _errorReportFile(String tag) {
    final String safe = tag.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').trim();
    final String stamp =
        _stamp().replaceAll(' ', '_').replaceAll(':', '-').replaceAll('.', '-');
    return File(
      '${_errorDir!.path}/error-$stamp-${safe.isEmpty ? "unknown" : safe}.log',
    );
  }

  String _errorReportText(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    final StringBuffer b = StringBuffer()
      ..writeln('time: ${DateTime.now().toIso8601String()}')
      ..writeln('platform: ${Platform.operatingSystem} ${Platform.version}')
      ..writeln('cwd: ${Directory.current.path}')
      ..writeln('tag: $tag')
      ..writeln('message: $message');
    if (error != null) b.writeln('error: $error');
    if (stack != null) {
      b.writeln('stack:');
      b.writeln(stack.toString().split('\n').take(40).join('\n'));
    }
    b
      ..writeln('normalLog: ${_current?.path ?? "(unavailable)"}')
      ..writeln('--- normal log tail ---')
      ..writeln(_readLogTail());
    return b.toString();
  }

  String _readLogTail({int maxLines = 80}) {
    final List<String> lines = <String>[];
    try {
      final File? f = _current;
      if (f != null && f.existsSync()) {
        lines.addAll(f.readAsStringSync().split('\n'));
      }
    } catch (_) {}
    // 尚在队列、尚未落盘的本次记录也要带上（例如触发错误报告的那条）。
    lines.addAll(_queue);
    final List<String> tail = lines.length <= maxLines
        ? lines
        : lines.sublist(lines.length - maxLines);
    return tail.join('\n').trim();
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

  /// 不在诊断日志或界面中暴露 API Key 字符、前缀或长度。
  static String keyFingerprint(String? key) =>
      key == null || key.isEmpty ? '(未配置)' : '已配置（隐藏）';

  String? get sessionTag => _sessionTag;

  Future<void> close() async {
    _timer?.cancel();
    _flush();
    try {
      // close() 会先冲刷缓冲区；不要再单独 flush()，否则可能触发绑定错误。
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }
}
