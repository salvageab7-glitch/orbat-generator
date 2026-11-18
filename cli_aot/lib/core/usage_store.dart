/// API 用量记录
///
/// 每次调用 DeepSeek 追加一行 JSON（JSONL 格式），追加写不会因为中途崩溃丢掉历史，
/// 也不需要在内存里维护全量数据。统计时按需读取、聚合。
///
/// 存储位置：与日志同级的 `usage.jsonl`
/// 单行格式：
///   {"t":"2026-11-18T10:30:00","scene":"识图","in":1831,"out":3200,"ms":10593,"model":"deepseek-flash"}
library;

import 'dart:convert';
import 'dart:io';

import 'logger.dart';

class UsageEntry {
  final DateTime time;
  final String scene;
  final int promptTokens;
  final int completionTokens;
  final int ms;
  final String model;

  const UsageEntry({
    required this.time,
    required this.scene,
    required this.promptTokens,
    required this.completionTokens,
    required this.ms,
    required this.model,
  });

  int get totalTokens => promptTokens + completionTokens;

  factory UsageEntry.fromJson(Map<String, dynamic> j) => UsageEntry(
        time: DateTime.tryParse((j['t'] ?? '').toString()) ?? DateTime.now(),
        scene: (j['scene'] ?? '').toString(),
        promptTokens: (j['in'] as num?)?.toInt() ?? 0,
        completionTokens: (j['out'] as num?)?.toInt() ?? 0,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        model: (j['model'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'scene': scene,
        'in': promptTokens,
        'out': completionTokens,
        'ms': ms,
        'model': model,
      };
}

class UsageSummary {
  final int todayCalls;
  final int todayIn;
  final int todayOut;
  final int monthCalls;
  final int monthIn;
  final int monthOut;
  final int totalCalls;

  const UsageSummary({
    this.todayCalls = 0,
    this.todayIn = 0,
    this.todayOut = 0,
    this.monthCalls = 0,
    this.monthIn = 0,
    this.monthOut = 0,
    this.totalCalls = 0,
  });

  int get todayTokens => todayIn + todayOut;
  int get monthTokens => monthIn + monthOut;
}

class UsageStore {
  UsageStore._();

  /// 追加一条用量记录。任何异常都吞掉——统计失败不能影响主流程。
  static Future<void> record({
    required String scene,
    required int promptTokens,
    required int completionTokens,
    required int ms,
    required String model,
  }) async {
    try {
      final f = _file();
      if (f == null) return;
      final entry = UsageEntry(
        time: DateTime.now(),
        scene: scene,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        ms: ms,
        model: model,
      );
      await f.writeAsString('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: false);
    } catch (_) {
      // 忽略
    }
  }

  /// 读取全部记录（按时间正序）
  static Future<List<UsageEntry>> loadAll() async {
    try {
      final f = _file();
      if (f == null || !f.existsSync()) return const [];
      final lines = await f.readAsLines();
      final out = <UsageEntry>[];
      for (final l in lines) {
        final t = l.trim();
        if (t.isEmpty) continue;
        try {
          out.add(UsageEntry.fromJson(
              jsonDecode(t) as Map<String, dynamic>));
        } catch (_) {
          // 跳过坏行，不影响其他记录
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<UsageSummary> summary() async {
    final all = await loadAll();
    final now = DateTime.now();
    var tCalls = 0, tIn = 0, tOut = 0;
    var mCalls = 0, mIn = 0, mOut = 0;

    for (final e in all) {
      final sameDay = e.time.year == now.year &&
          e.time.month == now.month &&
          e.time.day == now.day;
      final sameMonth =
          e.time.year == now.year && e.time.month == now.month;

      if (sameDay) {
        tCalls++;
        tIn += e.promptTokens;
        tOut += e.completionTokens;
      }
      if (sameMonth) {
        mCalls++;
        mIn += e.promptTokens;
        mOut += e.completionTokens;
      }
    }

    return UsageSummary(
      todayCalls: tCalls,
      todayIn: tIn,
      todayOut: tOut,
      monthCalls: mCalls,
      monthIn: mIn,
      monthOut: mOut,
      totalCalls: all.length,
    );
  }

  /// 最近 N 条（倒序）
  static Future<List<UsageEntry>> recent({int limit = 20}) async {
    final all = await loadAll();
    final rev = all.reversed.take(limit).toList();
    return rev;
  }

  static Future<void> clear() async {
    try {
      final f = _file();
      if (f != null && f.existsSync()) await f.delete();
    } catch (_) {}
  }

  static File? _file() {
    final dir = AppLogger.instance.logDirPath;
    if (dir == null) return null;
    final parent = Directory(dir).parent.path;
    return File('$parent/usage.jsonl');
  }

  static String? get filePath => _file()?.path;
}
