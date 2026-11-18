/// 批量任务队列
///
/// 设计原则（参考 Flutter 官方对 I/O 密集型任务的建议）：
///   · 识图/出图是**网络 + 文件 I/O**，不是 CPU 密集 → 用原生 async/await 串行循环，
///     **不需要 Isolate**（Isolate 只用于图片解码/切片那种 CPU 密集的环节，已在 image_prep 里）。
///   · 串行执行：不触发 API 限流，进度可预测，失败可精确定位。
///   · 失败跳过、单点重试：一个任务失败不阻塞整批。
///   · 状态外露给 UI：每个任务有明确的 status + 阶段 + 耗时，可实时刷新。
library;

import 'dart:async';

import '../core/logger.dart';

enum BatchStatus {
  pending, // 等待
  running, // 执行中
  generating, // 识图/生成中
  rendering, // 出图中
  done, // 成功
  failed, // 失败
  skipped, // 用户跳过
}

class BatchTask {
  final String id;
  final String sourcePath; // 图片路径（或文本）
  final String displayName;
  final String? extraText;

  BatchStatus status;
  String stage; // 当前阶段描述
  String? error;
  int? nodeCount;
  String? outputBase; // 出图输出基名
  String? pngPath;
  String? svgPath;
  String? jsonPath;
  int elapsedMs;
  int attempts;

  BatchTask({
    required this.id,
    required this.sourcePath,
    required this.displayName,
    this.extraText,
    this.status = BatchStatus.pending,
    this.stage = '',
    this.error,
    this.nodeCount,
    this.outputBase,
    this.pngPath,
    this.svgPath,
    this.jsonPath,
    this.elapsedMs = 0,
    this.attempts = 0,
  });

  bool get isFinished => const {
        BatchStatus.done,
        BatchStatus.failed,
        BatchStatus.skipped,
      }.contains(status);

  BatchTask copy() => BatchTask(
        id: id,
        sourcePath: sourcePath,
        displayName: displayName,
        extraText: extraText,
        status: status,
        stage: stage,
        error: error,
        nodeCount: nodeCount,
        outputBase: outputBase,
        pngPath: pngPath,
        svgPath: svgPath,
        jsonPath: jsonPath,
        elapsedMs: elapsedMs,
        attempts: attempts,
      );
}

/// 批处理回调
typedef BatchTaskCallback = void Function(BatchTask task, int index, int total);

/// 单个任务的执行器：由 UI 注入（因为要复用 OrbatPipeline）
typedef BatchTaskRunner = Future<BatchTaskResult> Function(
  BatchTask task,
  void Function(String stage) onStage,
);

class BatchTaskResult {
  final bool ok;
  final int? nodeCount;
  final String? outputBase;
  final String? pngPath;
  final String? svgPath;
  final String? jsonPath;
  final String? error;

  BatchTaskResult({
    required this.ok,
    this.nodeCount,
    this.outputBase,
    this.pngPath,
    this.svgPath,
    this.jsonPath,
    this.error,
  });
}

class BatchQueue {
  final List<BatchTask> _tasks = [];
  final BatchTaskRunner runner;
  final BatchTaskCallback? onUpdate;

  /// 取消标志：设为 true 后，当前任务完成后停止后续任务
  bool _cancelled = false;

  BatchQueue({required this.runner, this.onUpdate});

  List<BatchTask> get tasks => List.unmodifiable(_tasks);

  int get total => _tasks.length;
  int get doneCount =>
      _tasks.where((t) => t.status == BatchStatus.done).length;
  int get failedCount =>
      _tasks.where((t) => t.status == BatchStatus.failed).length;
  int get finishedCount => _tasks.where((t) => t.isFinished).length;
  bool get isRunning => _tasks.any((t) =>
      t.status == BatchStatus.running ||
      t.status == BatchStatus.generating ||
      t.status == BatchStatus.rendering);
  bool get isCancelled => _cancelled;

  void addAll(Iterable<BatchTask> tasks) {
    _tasks.addAll(tasks);
    _notifyAll();
  }

  void clear() {
    _tasks.clear();
    _cancelled = false;
    _notifyAll();
  }

  void cancel() {
    _cancelled = true;
    _notifyAll();
  }

  /// 串行执行所有 pending 任务
  Future<void> run() async {
    if (isRunning) return;
    _cancelled = false;
    final log = AppLogger.instance;
    log.section('批量任务开始: ${_tasks.length} 项');

    for (var i = 0; i < _tasks.length; i++) {
      if (_cancelled) {
        log.info('batch', '用户取消，剩余 ${_tasks.length - i} 项未处理');
        break;
      }

      final task = _tasks[i];
      if (task.status == BatchStatus.done ||
          task.status == BatchStatus.skipped) continue;

      final sw = Stopwatch()..start();
      _update(i, task, status: BatchStatus.running, stage: '准备中', attempts: task.attempts + 1);

      try {
        final result = await runner(task, (stage) {
          final s = switch (stage) {
            'generate' => BatchStatus.generating,
            'render' => BatchStatus.rendering,
            _ => BatchStatus.running,
          };
          _update(i, task, status: s, stage: stage);
        });

        if (result.ok) {
          _update(i, task,
              status: BatchStatus.done,
              stage: '完成',
              nodeCount: result.nodeCount,
              outputBase: result.outputBase,
              pngPath: result.pngPath,
              svgPath: result.svgPath,
              jsonPath: result.jsonPath,
              error: null);
          log.info('batch',
              '[${i + 1}/${_tasks.length}] ✓ ${task.displayName} '
              '${result.nodeCount ?? 0} 节点 ${sw.elapsed.inSeconds}s');
        } else {
          _update(i, task,
              status: BatchStatus.failed,
              stage: '失败',
              error: result.error ?? '未知错误');
          log.error('batch',
              '[${i + 1}/${_tasks.length}] ✗ ${task.displayName}: ${result.error}');
        }
      } catch (e, st) {
        _update(i, task,
            status: BatchStatus.failed, stage: '异常', error: e.toString());
        log.error('batch',
            '[${i + 1}/${_tasks.length}] ✗ ${task.displayName} 异常: $e', e, st);
      }

      _tasks[i].elapsedMs = sw.elapsedMilliseconds;
      _notifyAll();
    }

    log.info('batch',
        '批量结束: 成功 $doneCount / 失败 $failedCount / 总 $total');
  }

  /// 重试单个失败任务（不重跑整批）
  Future<void> retry(String taskId) async {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx < 0) return;
    final task = _tasks[idx];
    if (!task.isFinished) return;

    final log = AppLogger.instance;
    log.section('重试任务: ${task.displayName}');
    final sw = Stopwatch()..start();

    _update(idx, task,
        status: BatchStatus.running, stage: '重试中', error: null,
        attempts: task.attempts + 1);

    try {
      final result = await runner(task, (stage) {
        final s = switch (stage) {
          'generate' => BatchStatus.generating,
          'render' => BatchStatus.rendering,
          _ => BatchStatus.running,
        };
        _update(idx, task, status: s, stage: stage);
      });
      _update(idx, task,
          status: result.ok ? BatchStatus.done : BatchStatus.failed,
          stage: result.ok ? '重试成功' : '重试失败',
          nodeCount: result.nodeCount ?? task.nodeCount,
          outputBase: result.outputBase ?? task.outputBase,
          pngPath: result.pngPath ?? task.pngPath,
          svgPath: result.svgPath ?? task.svgPath,
          jsonPath: result.jsonPath ?? task.jsonPath,
          error: result.error);
      log.info('batch',
          '重试${result.ok ? "成功" : "失败"}: ${task.displayName} ${sw.elapsed.inSeconds}s');
    } catch (e) {
      _update(idx, task,
          status: BatchStatus.failed, stage: '重试异常', error: e.toString());
      log.error('batch', '重试异常: ${task.displayName}', e);
    }

    _tasks[idx].elapsedMs = sw.elapsedMilliseconds;
    _notifyAll();
  }

  void skip(String taskId) {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx >= 0) {
      _update(idx, _tasks[idx], status: BatchStatus.skipped, stage: '已跳过');
    }
  }

  void _update(
    int index,
    BatchTask source, {
    BatchStatus? status,
    String? stage,
    String? error,
    int? nodeCount,
    String? outputBase,
    String? pngPath,
    String? svgPath,
    String? jsonPath,
    int? attempts,
  }) {
    if (index >= _tasks.length) return;
    final t = _tasks[index];
    _tasks[index] = BatchTask(
      id: t.id,
      sourcePath: t.sourcePath,
      displayName: t.displayName,
      extraText: t.extraText,
      status: status ?? t.status,
      stage: stage ?? t.stage,
      error: error,
      nodeCount: nodeCount ?? t.nodeCount,
      outputBase: outputBase ?? t.outputBase,
      pngPath: pngPath ?? t.pngPath,
      svgPath: svgPath ?? t.svgPath,
      jsonPath: jsonPath ?? t.jsonPath,
      elapsedMs: t.elapsedMs,
      attempts: attempts ?? t.attempts,
    );
    onUpdate?.call(_tasks[index], index, _tasks.length);
  }

  void _notifyAll() {
    for (var i = 0; i < _tasks.length; i++) {
      onUpdate?.call(_tasks[i], i, _tasks.length);
    }
  }
}
