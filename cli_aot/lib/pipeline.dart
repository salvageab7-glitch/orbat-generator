/// 业务编排层 —— 把「AI 生成 → 本地校验 → 自我修复 → 出图」串成一条流水线
///
/// 纯 Dart（只依赖 dart:io），不依赖 Flutter，可以独立跑测试。
///
/// 核心设计：**自我修复循环**。模型生成的 SIDC 常有系统性错误（长度不对、
/// 符号集用错、编造实体码），本地校验器能精确指出，把错误回传给模型让它
/// 只修错处，比让模型一次到位可靠得多。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'core/orbat.dart';
import 'core/auto_fix.dart';
import 'core/logger.dart';
import 'core/dup_scan.dart';
import 'core/patch_repair.dart';
import 'core/sidc_audit.dart';
import 'core/sidc_rule.dart';
import 'ai/deepseek_client.dart';
import 'ai/image_prep.dart';
import 'ai/prompt.dart';
import 'render/renderer.dart';

/// 流水线各阶段回调，UI 拿来刷进度条
typedef StageCallback = void Function(String stage, String detail);

/// 一次生成的完整结果
class PipelineResult {
  final OrbatNode? tree;
  final ValidationReport? report;
  final String? rawJson;
  final String? error;
  final int aiAttempts; // AI 调用次数（含修复轮）
  final int repairRounds; // 实际执行的修复轮数
  final Duration elapsed;

  /// 识别失败或内容过少的图块元数据（供单点重试）。
  /// 每项是一块裁切信息，可由 retry-tile 命令单独重识别。
  final List<Map<String, dynamic>> failedTiles;

  /// 本次用的图块总数
  final int totalTiles;

  /// SIDC 一致性审计发现并已修正的项（模型码 vs 本地规则）。
  /// 这些不是"校验失败"，而是"模型给的码与名称不自洽"，修正后图才是对的。
  final List<AuditIssue> auditIssues;

  PipelineResult({
    this.tree,
    this.report,
    this.rawJson,
    this.error,
    this.aiAttempts = 0,
    this.repairRounds = 0,
    required this.elapsed,
    this.failedTiles = const [],
    this.totalTiles = 0,
    this.auditIssues = const [],
  });

  bool get ok => tree != null && (report?.ok ?? false);
}

class OrbatPipeline {
  final String apiKey;
  final String model;
  final String? renderScriptPath;
  final int maxRepairRounds;

  /// PNG 白底开关（false = 透明底）
  final bool whiteBackground;

  /// 输出语言：true = JSON 全中文（名称译成中文）；false = 保留原文称号/番号/注释
  final bool forceChinese;

  OrbatPipeline({
    required this.apiKey,
    this.model = 'deepseek-flash',
    this.renderScriptPath,
    this.maxRepairRounds = 2,
    this.whiteBackground = true,
    this.forceChinese = true,
  });

  /// 从图片生成编制。
  ///
  /// **大图会自动切片**：模型对图片的处理预算固定（约 1020 token），
  /// 整张 7000+ 像素的编制图传进去会被压成极小缩略图，文字全糊。
  /// 所以先按网格切片，逐块识别后合并。
  Future<PipelineResult> fromImage(
    File image, {
    String? extraText,
    StageCallback? onStage,
  }) async {
    final sw = Stopwatch()..start();
    final log = AppLogger.instance;
    log.section('识别: ${image.path}');
    final bytes = await image.readAsBytes();
    final mime = _mimeOf(image.path);
    log.info('image', '文件 ${(bytes.length / 1024).toStringAsFixed(0)}KB, 类型 $mime, '
        'key=${AppLogger.keyFingerprint(apiKey)}, model=$model');

    // ---- 1) 预处理：判断整张发还是切片 ----
    //
    // 注意：切片**不能**轻易降级成整图。超宽/超高图整张发送时，
    // 模型只能看到极小缩略图，识别结果必然是错的（实测 35168px 宽的图
    // 整张发出去只认出 51 个节点，正确应为 96 个）。
    // 所以后台 isolate 失败时，退回主线程再试一次，而不是放弃切片。
    onStage?.call('预处理', '正在分析图片尺寸…');
    TilePlan? plan;
    try {
      plan = await Isolate.run(() => prepareTiles(bytes));
    } catch (e) {
      onStage?.call('预处理', '后台解码失败，改用主线程解码（界面会短暂卡顿）…');
      try {
        plan = prepareTiles(bytes);
      } catch (e2) {
        return PipelineResult(
          error: '图片解码失败，无法切片识别：$e2\n'
              '（后台解码错误：$e）',
          elapsed: sw.elapsed,
        );
      }
    }

    if (plan == null) {
      return PipelineResult(
        error: '图片预处理未返回结果，已中止（不做整图识别，避免输出错误结构）。',
        elapsed: sw.elapsed,
      );
    }

    // ---- 2) 大图：逐块读图 ----
    // 关键：这一步只让模型「读出名字和层级」，不要求它构造 SIDC。
    // 实测同一块图，只问名称能 11 个单位全对；带上完整 SIDC 规范就会
    // 出现「第1MT连」这类截断和「无法识别」占位。SIDC 交给本地规则引擎。
    onStage?.call('切片', plan.summary);
    log.info('slice', '${plan.summary} | 原图 ${plan.srcWidth}×${plan.srcHeight}');
    for (final t in plan.tiles) {
      log.debug('slice', '${t.label} 裁切 ${t.srcW}×${t.srcH} @(${t.srcX},${t.srcY}) → ${t.sizeKb}KB');
    }
    final client = DeepSeekClient(
      config: DeepSeekConfig(apiKey: apiKey, model: model),
      systemPrompt: kTileSystemPrompt,
    );

    final trees = <({OrbatNode tree, ImageTile tile})>[];
    final failedTiles = <Map<String, dynamic>>[];
    final tiles = plan.tiles;
    final isWideLayout = tiles.first.totalCols > tiles.first.totalRows * 2;
    var attempts = 0;
    try {
      for (var i = 0; i < tiles.length; i++) {
        final t = tiles[i];
        onStage?.call('分块识别', '${i + 1}/${tiles.length} · ${t.label}');

        final prompt = buildTileReadPrompt(
          index: i,
          total: tiles.length,
          tile: t,
          isWideLayout: isWideLayout,
          extraText: extraText,
          forceChinese: forceChinese,
        );

        final text = await client.generateTextFromImage(
          imageBytes: t.png,
          mimeType: 'image/png',
          prompt: prompt,
        );
        attempts++;

        // 模型按「观察 / json / 自检」三段输出，取出 <json> 段解析
        OrbatNode? tree;
        final jsonBlock = text != null ? extractJsonBlock(text) : null;
        if (jsonBlock != null) {
          try {
            final parsed = jsonDecode(jsonBlock) as Map<String, dynamic>;
            tree = OrbatNode.fromJson(parsed);
          } catch (e) {
            onStage?.call('分块识别', '${t.label} JSON 解析失败：$e');
          }
        }

        // 有效内容太少（常见于单位正好被切在块边界）→ 重试一次。
        // 但密集图（切成 3 块以上）不重试：那种块一次失败多是内容过多/超时，
        // 重试只会再等一轮（实测让整张图从 37 秒拖到 219 秒），得不偿失。
        final retryAllowed = tiles.length <= 2;
        if ((tree == null || tree.count < 3) && retryAllowed) {
          onStage?.call('分块识别',
              '${t.label} 有效内容过少（${tree?.count ?? 0} 节点），重试…');
          final text2 = await client.generateTextFromImage(
            imageBytes: t.png,
            mimeType: 'image/png',
            prompt: '$prompt\n\n'
                '注意：上一次几乎没读出内容。请再逐行仔细扫描这张图，'
                '把能辨认的单位都输出（宁少勿编），名称务必完整。',
          );
          attempts++;
          final jsonBlock2 =
              text2 != null ? extractJsonBlock(text2) : null;
          if (jsonBlock2 != null) {
            try {
              final p2 = jsonDecode(jsonBlock2) as Map<String, dynamic>;
              final t2 = OrbatNode.fromJson(p2);
              if (t2.count > (tree?.count ?? 0)) tree = t2;
            } catch (_) {}
          }
        }

        if (tree != null && tree.count >= 1) {
          log.info('tile', '${t.label} → ${tree.count} 节点, 根「${tree.uniqueDesignation}」');
          trees.add((tree: tree, tile: t));
          onStage?.call('分块识别',
              '${t.label} 完成：${tree.count} 节点，根「${tree.uniqueDesignation}」'
              '（累计 ${trees.length}/${tiles.length} 块）');
        } else {
          onStage?.call('分块识别', '${t.label} 无有效内容，跳过');
          failedTiles.add({
            'row': t.row,
            'col': t.col,
            'totalRows': t.totalRows,
            'totalCols': t.totalCols,
            'srcX': t.srcX,
            'srcY': t.srcY,
            'srcW': t.srcW,
            'srcH': t.srcH,
            'label': t.label,
            'reason': '无有效内容',
          });
        }
      }
    } finally {
      client.close();
    }

    if (trees.isEmpty) {
      return PipelineResult(
        error: '所有图块都识别失败，请检查网络或换一张更清晰的图。',
        aiAttempts: attempts,
        elapsed: sw.elapsed,
      );
    }

    // ---- 3) 合并 ----
    final hint = parseStructureHint(extraText);
    if (!hint.isEmpty) {
      onStage?.call('合并',
          '使用结构提示：总根 ${hint.rootName ?? "（自动判断）"}'
          '${hint.branches.isEmpty ? "" : "，分支 ${hint.branches.join("、")}"}');
    }
    onStage?.call('合并', '正在合并 ${trees.length} 块结果…');
    log.info('merge', '开始合并 ${trees.length} 块, 提示=${hint.isEmpty ? "无" : hint}');
    var merged = mergeTileTrees(trees, hint: hint);
    final mergedBefore = merged.count;

    // 说明：早先这里还有「层级倒挂提升」和「名称碎片合并」两步本地改写。
    // 改用 agent 式提示词（先观察→再逐段拼 SIDC→后自检）后，模型输出本身
    // 已不再产生「旅部挂在营下」「炮兵」这类问题，这两步成了空转，
    // 还带来把正确结果改坏的风险（实测去重反而让节点数从 71 涨到 80），故移除。

    // A4：跨父节点同名合并（分块边界常把同一单位挂到两个父节点下）
    final dupLog = <String>[];
    final dupMerged = autoMerge(merged, log: dupLog);
    if (dupMerged > 0) {
      log.info('dup', '跨块同名合并 $dupMerged 处');
      for (final l in dupLog.take(20)) {
        log.warn('dup', l);
      }
      onStage?.call('合并', '合并跨块重复单位 $dupMerged 处');
    }

    // 先本地机械修复（SIDC 位数、括号、注释长度），避免模型重写整棵树丢数据
    merged = OrbatAutoFix.apply(merged);

    // SIDC 一致性审计（v0.4 / A1）：模型给的码与名称不自洽时按名称裁决。
    // 放在校验之前——审计修完，红牌数量才是真实水平。
    final audit = SidcAudit.auditAndFix(merged);
    merged = audit.tree;
    final auditIssues = audit.issues;
    if (auditIssues.isNotEmpty) {
      log.info('audit', '一致性审计修正 ${auditIssues.length} 处');
      for (final a in auditIssues.take(20)) {
        log.warn('audit', '${a.path}: ${a.reason}');
      }
      onStage?.call('审计', '名称与 SIDC 不一致 ${auditIssues.length} 处，已按名称修正');
    }

    var report = OrbatValidator.validate(merged);
    log.info('merge', '合并结果 $mergedBefore → ${merged.count} 节点, 层级 ${merged.maxDepth}, '
        '红牌 ${report.redCount} 软警告 ${report.warnCount}');
    for (final i in report.issues.take(20)) {
      log.warn('validate', '${i.level} ${i.path}: ${i.message}');
    }
    onStage?.call('合并',
        '合并 ${trees.length} 块 → $mergedBefore 节点，本地修复后红牌 ${report.redCount}');
    var repairs = 0;

    // 合并后仍可能有红牌，走一次修复
    while (!report.ok && repairs < maxRepairRounds) {
      repairs++;
      onStage?.call('修复', '发现 ${report.redCount} 个红牌错误，第 $repairs 轮修复…');
      final redIssues = report.issues.where((i) => i.level == 'red').toList();
      final repairPrompt = _buildPatchPrompt(merged, redIssues);
      final c2 = DeepSeekClient(
        config: DeepSeekConfig(apiKey: apiKey, model: model),
        systemPrompt: kOrbatSystemPrompt,
      );
      try {
        final fixed = await c2.generateFromText(repairPrompt,
            onProgress: (p) => onStage?.call('修复', p));
        attempts += fixed.attempts;
        if (!fixed.ok) break;
        // A3：只应用补丁，绝不替换整棵树（模型重写会丢节点，见 auto_fix.dart 注释）
        final patches = parsePatchList(fixed.rawJson);
        if (patches.isEmpty) {
          onStage?.call('修复', '模型未返回可用补丁，保留本地修复结果');
          break;
        }
        final res = applyPatches(merged, patches);
        if (!res.ok) {
          onStage?.call('修复', '补丁路径全部未命中，保留本地修复结果');
          break;
        }
        merged = OrbatAutoFix.apply(res.tree);
        report = OrbatValidator.validate(merged);
        onStage?.call('修复',
            '第 $repairs 轮：应用 ${res.applied} 条补丁（跳过 ${res.skipped.length} 条），'
            '红牌 ${report.redCount}');
      } finally {
        c2.close();
      }
    }

    onStage?.call('完成',
        '合并 ${trees.length} 块 → ${merged.count} 节点，层级 ${merged.maxDepth}，红牌 ${report.redCount}');

    final jsonStr = normalizeTreeJson(merged);
    await AppLogger.instance.saveSnapshot(
      merged.uniqueDesignation,
      json: jsonStr,
    );
    log.info('pipeline', '识别完成: ${merged.count} 节点, 层级 ${merged.maxDepth}, '
        'AI 调用 $attempts 次, 修复 $repairs 轮, 用时 ${sw.elapsed.inSeconds}s');

    return PipelineResult(
      tree: merged,
      report: report,
      rawJson: normalizeTreeJson(merged),
      aiAttempts: attempts,
      repairRounds: repairs,
      elapsed: sw.elapsed,
      failedTiles: failedTiles,
      totalTiles: tiles.length,
      auditIssues: auditIssues,
    );
  }

  /// 从文字生成编制
  Future<PipelineResult> fromText(
    String text, {
    StageCallback? onStage,
  }) async {
    final sw = Stopwatch()..start();
    return _generate(
      onStage: onStage,
      sw: sw,
      callAi: (client) =>
          client.generateFromText(text, onProgress: (p) => onStage?.call('识别', p)),
    );
  }

  Future<PipelineResult> _generate({
    required StageCallback? onStage,
    required Stopwatch sw,
    required Future<GenerateResult> Function(DeepSeekClient) callAi,
  }) async {
    final client = DeepSeekClient(
      config: DeepSeekConfig(apiKey: apiKey, model: model),
      systemPrompt: kOrbatSystemPrompt,
    );

    try {
      onStage?.call('识别', '正在调用 DeepSeek 识别编制结构…');
      final first = await callAi(client);
      if (!first.ok) {
        return PipelineResult(
          rawJson: first.rawJson,
          error: first.error,
          aiAttempts: first.attempts,
          elapsed: sw.elapsed,
        );
      }

      var tree = OrbatAutoFix.apply(first.tree!);
      // 文字模式同样过一遍一致性审计（A1），口径与图像模式一致
      final audit = SidcAudit.auditAndFix(tree);
      tree = audit.tree;
      var report = OrbatValidator.validate(tree);
      var attempts = first.attempts;
      var repairs = 0;

      // 自我修复：有红牌就把具体错误回传，让模型只修错处
      while (!report.ok && repairs < maxRepairRounds) {
        repairs++;
        onStage?.call('修复', '发现 ${report.redCount} 个红牌错误，第 $repairs 轮修复…');

        final redIssues = report.issues.where((i) => i.level == 'red').toList();
        final repairPrompt = _buildPatchPrompt(tree, redIssues);

        final fixed = await client.generateFromText(
          repairPrompt,
          onProgress: (p) => onStage?.call('修复', p),
        );
        attempts += fixed.attempts;

        if (!fixed.ok) {
          onStage?.call('修复', '第 $repairs 轮修复未返回有效 JSON，保留原结果');
          break;
        }

        // A3：补丁式修复，不接收整棵树
        final patches = parsePatchList(fixed.rawJson);
        final res = applyPatches(tree, patches);
        if (patches.isEmpty || !res.ok) {
          onStage?.call('修复', '模型未返回可用补丁，保留原结果');
          break;
        }
        tree = OrbatAutoFix.apply(res.tree);
        report = OrbatValidator.validate(tree);
        onStage?.call('修复',
            '第 $repairs 轮完成：红牌 ${report.redCount}，软警告 ${report.warnCount}');
      }

      onStage?.call('完成',
          '生成 ${tree.count} 节点，层级 ${tree.maxDepth}，红牌 ${report.redCount}');

      return PipelineResult(
        tree: tree,
        report: report,
        rawJson: normalizeTreeJson(tree),
        aiAttempts: attempts,
        repairRounds: repairs,
        elapsed: sw.elapsed,
        auditIssues: audit.issues,
      );
    } finally {
      client.close();
    }
  }

  /// 补丁式修复指令（A3）：只给"有问题节点"的当前字段，要求模型回补丁。
  ///
  /// 为什么不再让模型返回整棵树：实测 176 节点的编制经模型"修一遍"只剩 32 个
  /// （见 auto_fix.dart 开头注释）。补丁模式下模型输出极小，且路径不命中会被丢弃，
  /// 最坏情况只是修不动，不会丢数据。
  String _buildPatchPrompt(OrbatNode tree, List<ValidationIssue> issues) {
    final buf = StringBuffer();
    buf.writeln('你上一次输出的编制 JSON 有 ${issues.length} 处必须修正的错误。');
    buf.writeln('**只返回补丁，不要返回整棵树**（整树会被程序拒绝应用）。');
    buf.writeln();
    buf.writeln('## 错误清单');
    for (final i in issues.take(30)) {
      buf.writeln('- ${i.path}: ${i.message}');
    }
    buf.writeln();
    buf.writeln('## 相关节点的当前内容');
    final seen = <String>{};
    for (final i in issues.take(30)) {
      if (!seen.add(i.path)) continue;
      final node = _nodeAt(tree, i.path);
      if (node == null) continue;
      buf.writeln(jsonEncode({
        'path': i.path,
        'uniqueDesignation': node.uniqueDesignation,
        'additionalInformation': node.additionalInformation,
        'sidc': node.sidc,
      }));
    }
    buf.writeln();
    buf.writeln('## 输出格式（严格）');
    buf.writeln('{"patches":[{"path":"根/第1旅/第2营","sidc":"30位数字"}]}');
    buf.writeln('规则：');
    buf.writeln('1. path 必须与错误清单里的路径逐字一致，不要新建路径。');
    buf.writeln('2. 只写要改的字段（sidc / name / note），没问题的字段不要出现。');
    buf.writeln('3. sidc 必须正好 30 位数字；注释 ≤12 汉字或 ≤20 字母。');
    buf.writeln('4. 不要新增、删除、移动任何节点。');
    return buf.toString();
  }

  /// 按「根/第1旅/第2营」路径取节点（与校验器拼路径的规则一致）
  static OrbatNode? _nodeAt(OrbatNode root, String path) {
    final segs = path
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (segs.isNotEmpty && (segs.first == '根' || segs.first == 'root')) {
      segs.removeAt(0);
    }
    if (segs.isNotEmpty && segs.first == root.uniqueDesignation) segs.removeAt(0);

    var cur = root;
    for (final seg in segs) {
      OrbatNode? next;
      for (final c in cur.children) {
        if (c.uniqueDesignation == seg) {
          next = c;
          break;
        }
      }
      if (next == null) return null;
      cur = next;
    }
    return cur;
  }

  /// 出图。[onLog] 用于把渲染脚本的每一行输出实时推给界面。
  Future<RenderResult> render(
    OrbatNode tree, {
    required String outputBase,
    StageCallback? onStage,
    void Function(String line)? onLog,
  }) async {
    final script = renderScriptPath;
    if (script == null || script.trim().isEmpty) {
      return RenderResult(
        ok: false,
        error: '未配置渲染脚本路径。请在设置里指定 render_orbat.js 的完整路径。',
        elapsed: Duration.zero,
      );
    }
    onStage?.call('出图', '正在调用线上渲染器（联网，约 15-60 秒）…');
    final renderer = OrbatRenderer(RendererConfig(
        scriptPath: script,
        whiteBackground: whiteBackground,
      ));
    final result = await renderer.render(
      // 只有送渲染器这一步才做名称长度适配；导出/保存的 JSON 保持原文
      normalizedJson: normalizeTreeJson(tree, adaptForRender: true),
      outputBase: outputBase,
      onLog: onLog,
    );
    if (result.ok) {
      onStage?.call('出图', '出图完成');
    } else {
      onStage?.call('出图', '出图失败：${result.error}');
    }
    return result;
  }

  static String _mimeOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/png';
  }
}

/// 树 → 归一化 JSON 字符串（带缩进，便于人工查看/编辑）
/// 树 → 归一化 JSON
///
/// **commandLevels 必须是 '3'**：实测这个值直接决定渲染器的排布策略。
/// 设 2 时，只有下属超过 8 个的分支才会纵向排列，2-3 个下属的分支一律横向铺开，
/// 导致同一张图里有的分支竖着、有的横着，观感参差；
/// 设 3 时全部按纵向展开，图也更紧凑（同一张法国团级图宽度从 3331 降到 1448）。
String normalizeTreeJson(OrbatNode tree,
    {String commandLevels = '3', bool adaptForRender = false}) {
  return const JsonEncoder.withIndent('  ').convert(normalizeTree(tree,
      commandLevels: commandLevels, adaptForRender: adaptForRender));
}

/// 从补充说明里解析出来的结构提示。
///
/// 超宽编制图（如 35168×2952）切片后每块只有局部信息，无法自动判断总根和归属。
/// 支持两种写法：
///
/// **简单版**（只定总根和二级分支）：
/// ```
/// 总根：第1近卫机械化师
/// 下辖：师部、第453机械化旅、第51机械化旅
/// ```
///
/// **骨架版**（推荐，能还原完整层级）：
/// ```
/// 第1近卫机械化师
/// - 师部
/// - 第453机械化旅
///   - 第2装甲营
///   - 第1机械化营
/// - 第51机械化旅
/// ```
/// 缩进用空格/tab，行首可用 `-`/`*`/`├`/`└`/`│`。
class StructureHint {
  final String? rootName;
  final List<String> branches;

  /// 解析出的骨架树（骨架版才有）
  final OrbatNode? skeleton;

  const StructureHint({
    this.rootName,
    this.branches = const [],
    this.skeleton,
  });

  bool get isEmpty => rootName == null && branches.isEmpty && skeleton == null;

  @override
  String toString() => 'StructureHint(root=$rootName, '
      'branches=${branches.join("/")}, skeleton=${skeleton?.count ?? 0}节点)';
}

/// 解析结构提示
StructureHint parseStructureHint(String? text) {
  if (text == null || text.trim().isEmpty) return const StructureHint();
  final t = text;

  // ---- 显式标注的总根 ----
  String? root;
  final rootMatch = RegExp(
          r'(?:总根|根单位|最高单位|顶层单位|总称|上级单位)\s*[:：]\s*([^\n\r，,；;]+)')
      .firstMatch(t);
  if (rootMatch != null) {
    root = rootMatch.group(1)!.trim();
    if (root.isEmpty) root = null;
  }

  // ---- 显式标注的二级分支 ----
  final branches = <String>[];
  final brMatch = RegExp(r'(?:下辖|下属|二级单位|分支|直属)\s*[:：]\s*([^\n\r]+)')
      .firstMatch(t);
  if (brMatch != null) {
    branches.addAll(brMatch
        .group(1)!
        .split(RegExp(r'[、,，;；/]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty));
  }

  // ---- 骨架版：按缩进解析 ----
  final skeleton = _parseSkeleton(t);
  if (skeleton != null && root == null) {
    root = skeleton.uniqueDesignation;
  }

  return StructureHint(
    rootName: root,
    branches: branches,
    skeleton: skeleton,
  );
}

/// 从文本里解析出缩进树；解析不出层级（只有一行或没有缩进）时返回 null
OrbatNode? _parseSkeleton(String text) {
  final entries = <({int indent, String name})>[];

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    var line = rawLine;
    // 剥掉行首的树形符号，但先记下缩进
    final indent = _indentWidth(line);

    line = line.replaceFirst(RegExp(r'^\s*'), '');
    line = line.replaceAll(RegExp(r'^[│├└─\-*·•+>\s]+'), '');
    line = line.trim();

    if (line.isEmpty) continue;
    // 跳过"总根：""下辖："这类说明行
    if (RegExp(r'^(总根|根单位|最高单位|顶层单位|下辖|下属|二级单位|分支|直属|补充说明)')
        .hasMatch(line)) {
      continue;
    }
    // 名字太长的不像单位名
    if (line.length > 40) continue;

    entries.add((indent: indent, name: line));
  }

  if (entries.length < 2) return null;

  // 至少要有两级缩进，否则不算骨架
  final minIndent = entries.map((e) => e.indent).reduce((a, b) => a < b ? a : b);
  final hasNesting = entries.any((e) => e.indent > minIndent);
  if (!hasNesting) return null;

  final rootEntry = entries.first;
  final root = OrbatNode(
    uniqueDesignation: rootEntry.name,
    additionalInformation: '',
    sidc: _guessSidcForName(rootEntry.name),
  );

  // 用缩进栈构建
  final stack = <({int indent, OrbatNode node})>[(indent: rootEntry.indent, node: root)];
  for (final e in entries.skip(1)) {
    while (stack.length > 1 && stack.last.indent >= e.indent) {
      stack.removeLast();
    }
    final parent = stack.last.node;

    // 同名兄弟直接复用，避免重复
    OrbatNode? existing;
    for (final c in parent.children) {
      if (c.uniqueDesignation == e.name) {
        existing = c;
        break;
      }
    }
    final node = existing ??
        OrbatNode(
          uniqueDesignation: e.name,
          additionalInformation: '',
          sidc: _guessSidcForName(e.name),
        );
    if (existing == null) parent.children.add(node);
    stack.add((indent: e.indent, node: node));
  }

  return root;
}

/// 分块读图的提示词 —— agent 风格：先观察、再构造、后自检。
///
/// 这是实测出来的关键结论：
///   · 直接要求模型输出 JSON（带 SIDC 规范）→ SIDC 会整体左移 4 位（漏了符号集和固定位）
///   · 加上「先写观察、再逐段拼接 SIDC、最后自检」的流程 → SIDC 100% 正确
/// 模型有能力一次做对，前提是把工作流程拆给它，而不是把规则堆给它。
/// 读图用的 system prompt —— **规则全部放这里**。
///
/// 关键经验：把规则塞进 user message 会让模型把"规则"当成"本次任务的描述"，
/// 注意力被摊薄，层级判断明显变差（实测同一张图，规则在 system 时 12 个二级全对，
/// 挪到 user 里只有 8 个）。所以 system 承载全部设定，user 只交代"这是第几块"。
const String kTileSystemPrompt = r"""
# 角色
你是军事编制图（ORBAT）转写专家，能把编制图精确转写为结构化 JSON。

# 工作流程（必须遵守）
1. **观察**：先在心里逐行扫描图片，看清有哪些单位、各自层级。
   <观察> 段的**第一行必须写** `方框计数：N`（这张图块里有几个独立的单位方框），
   然后只列 5-15 个关键单位（根节点 + 各主要分支 + 容易看错的型号名），
   用来核对下面 JSON 没漏掉大枝。**不要把每个单位都列出来**——
   完整清单在 <json> 里写一次就够，观察段重复列一遍会耗尽 token 导致 JSON 被截断。
   看不清的标 [?]，不要猜。
2. **构造**：按观察结果和连线关系构造 JSON。父子关系只看连线，不靠位置远近。
   图上所有单位都要进 JSON，一个都不能漏。
3. **自检（交付前必须通过）**：做三件事——
   a. **节点核对**：数一遍 <json> 里的节点总数 M，与 `方框计数 N` 对比，
      自检段必须写出 `节点核对：JSON M 个节点 / 方框 N 个`。
      M 与 N 不一致时，回头找漏掉或多出的单位并改正（改完再核一次）。
   b. 格式核对：SIDC 是否 30 位、名称是否与图中文字一致。
   c. **逐框溯源**：对 <json> 里写下的每一个节点，回图确认它是否真有一个独立方框。
      图上找不到对应框的就是凭空生成，**必须从 JSON 里删掉**，并在 <自检> 段列出
      「已删除：xxx（图上无此框）」。看不清、不能 100% 确认的，保留但名称后标 [?]。

# 层级判据（自检段必须声明用了哪一种）
- 优先看**连线**：直属分队与各营是平级的，都单独接到上级横线；
  不要因为它们画在某个营旁边或纵向对齐，就写成那个营的下属。
- 没有连线时依次退化：横向缩进 → 纵向包含（父框把子框框在里面）。
- 自检段必须写一行 `判据：连线` / `判据：缩进` / `判据：纵向包含`
  （多种混用时写 `判据：连线+缩进`）。有"看起来从属但没画线"的判断要单独说明。
- **层级深度完全由图上画法决定**，不要套用「师→旅→营→连」的固定惯例。
  某个营下面没有连线、没有下级方框，就绝不能给它补「第1连/第2连/第3连」。

# 编制图常识
一个旅/师通常下辖：若干营 + 若干直属分队（旅部及旅部连、防空连、侦察连、工兵连、
通信连、保障分队、防化连等）。直属分队与各营平级。

# 外文层级词 → 中文层级词（译名必须用表中的词，不得自由发挥）
Division→师　Brigade→旅　Regiment→团　Battalion→营　Company→连　Platoon→排
Squadron→营（骑兵/航空）　Troop→连（骑兵）　Battery→连（炮兵）　Squad→班　Team→组
Corps→军　Army→集团军　Army Group→方面军　Theater→战区
Дивизия→师　Бригада→旅　Полк→团　Батальон→营　Рота→连　Взвод→排　Батарея→炮兵连　Корпус→军
（表里没有的按原意译，并在自检段列出该词）

# SIDC 构造（30 位纯数字）
格式：1303 | 符号集 | 00 | 梯队 | 主实体 | 类型 | 机动 | 扇区 | 00000000

**必须逐段写出来再拼接，禁止凭记忆直接写 30 位**：
  营级反坦克：1303 | 10 | 00 | 16 | 120400 | 00 | 00 | 00 | 00000000
             = 130310001612040000000000000000
  连级步兵　：1303 | 10 | 00 | 15 | 121100 | 00 | 00 | 00 | 00000000
             = 130310001512110000000000000000

第二段必须是 10（陆地）或 01（空中），第三段必须是 00。漏写这两段会让整串左移 4 位。

梯队：14排 15连 16营 17团 18旅 21师 22军 23集团军
主实体：110000司令部 121100步兵 121105步兵战车 121102装甲机械化 121104摩托化 120500装甲 120400反坦克
　　　　130300炮兵(通用) 130301自行火炮履带 130800迫击炮 130100防空 130101高炮 121300侦察 121600雷达站
　　　　140700工兵 160000勤务支援 161300医疗/卫生 160800军法署 150500电子战 110500联络 111000通信 120600陆军航空兵
修饰位全部禁用：主实体6位之后的14位（类型2+机动2+扇区2+保留8）一律全0，不写任何小标志；载具/口径等细节靠名称表达。例：摩托化步兵=...121104 00 00 00...、自行火炮=...130301 00 00 00...、火箭炮=...130300 00 00 00...

# 输出格式
严格按三段输出，顺序不可变，不要输出其他内容：
<观察>
方框计数：N
（5-15 个关键单位，标清层级）
</观察>
<json>
{"options":{"uniqueDesignation":"名称","additionalInformation":"注释","sidc":"30位"},"subOrganizations":[...],"commandLevels":"1"}
</json>
<自检>
节点核对：JSON M 个节点 / 方框 N 个
判据：连线
已删除（图上无对应方框，已从 JSON 移除）：
  - ...
待确认（图上看不清，已标 [?] 保留）：
  - ...
格式核对：SIDC 位数 ✓ / 名称与图中一致 ✓
</自检>

commandLevels 只在根节点出现；子节点不要写这个字段。

# 铁律
- 名称照抄图中文字，含型号，不得概括（「第1МТ-12炮连」不能写成「第1反坦克连」）
- **部队称号并入名称**：荣誉名、地名冠名（如「近卫」「莫斯科」）写在
  uniqueDesignation 里，不要塞进注释。
- **注释只写两项内容**：驻地，或职能短名。硬上限 **12 个汉字（英文等拼音文字 20 个字母）**。
  不写指挥官姓名，不写装备清单长句，不写自检说明。
- 名称里禁止「空格+左括号」；层级词必须照抄（写「旅」不能写成「师」）。
- 只写图中真实存在的单位，不推测、不补全其他区域。
  **每个节点都必须能在图上找到一个独立的方框**，画不出对应框的单位就是臆造，必须删掉。
- **警惕「同构复制」脑补**：若同一上级下多个分支的子节点清单完全相同
  （三个营都写着「营部+第1连+第2连+第3连」），这是「看清一处就复制到其他处」的臆造信号，
  **必须回图逐个分支确认**——很可能图上前两个营根本没画连级单位。
- **营级及以上必须逐个建节点，禁止 ×N 合并**：师下属旅/团、旅下属营、团下属营、
  军下属师/旅、集团军下属军/师/旅，都必须分开写。
- **连、排级的同构单位可以合并**写成「××连×3」，前提是没有番号/装备/驻地差异。
""";

/// 读图用的 user prompt —— 只说"这是哪一块"，规则不重复。
///
/// [forceChinese] 来自界面「全中文输出」开关（默认勾选）：
///   true  → 名称与注释都输出中文（外文单位译名）
///   false → 保留原文称号/番号，注释同样保留原文，便于与原图逐字对照
String buildTileReadPrompt({
  required int index,
  required int total,
  required ImageTile tile,
  required bool isWideLayout,
  String? extraText,
  bool forceChinese = true,
}) {
  final b = StringBuffer();

  if (total <= 1) {
    b.writeln('请按工作流程处理这整张编制图。');
  } else {
    b.writeln('这是整张编制图的第 ${index + 1} 块（共 $total 块，${tile.label}），'
        '请按工作流程处理这部分。');
    // 边界提醒（A4）：相邻块有 12% 重叠，被切断的单位不要猜全名
    b.writeln('本块与相邻块有重叠区。落在本块边缘、方框被切断的单位，'
        '只写看得见的部分并在名称后标 [?]，不要凭常识补全全名。');
    if (isWideLayout) {
      b.writeln('整图横向展开，当前是第 ${tile.col + 1} 列（共 ${tile.totalCols} 列）。'
          '${tile.col == 0 ? "最左侧通常是最顶层的总单位。" : "这块大概率是某个上级单位的下属分支。"}');
    }
  }

  // 输出语言：按钮级开关，单选题，放 user 里最清晰
  b.writeln('');
  if (forceChinese) {
    b.writeln('输出语言：**全中文**。uniqueDesignation 必须用中文（外文单位按外文层级词表'
        '译成规范中文军语）；additionalInformation 也用中文（驻地/职能短名）。'
        '原文缩写可保留在注释里，但注释仍受 12 汉字上限约束。');
  } else {
    b.writeln('输出语言：**保留原文**。uniqueDesignation 用图中原文的称号与番号，'
        '不要翻译（如「2nd Battalion, 12th Regiment」就照抄）；'
        'additionalInformation 同样保留原文。层级判断仍按外文层级词表进行。');
  }

  if (extraText != null && extraText.trim().isNotEmpty) {
    b.writeln('');
    b.writeln('补充说明（含结构提示，请优先遵循）：');
    b.writeln(extraText.trim());
  }

  return b.toString();
}

/// 从模型的三段式输出里取出 <json> 内容
String? extractJsonBlock(String text) {
  final m = RegExp(r'<json>([\s\S]*?)</json>').firstMatch(text);
  if (m != null) return m.group(1)!.trim();
  // 兜底：找第一个 { 到最后一个 }
  final i = text.indexOf('{');
  final j = text.lastIndexOf('}');
  if (i >= 0 && j > i) return text.substring(i, j + 1);
  return null;
}

/// 解析「缩进树」文本 → OrbatNode，SIDC 由本地规则引擎生成
OrbatNode? parseUnitList(String text) {
  final entries = <({int indent, String name, String note})>[];

  for (final raw in text.split(RegExp(r'\r?\n'))) {
    var line = raw;
    // 剥掉代码块标记
    if (line.trim().startsWith('```')) continue;

    final indent = _indentWidth(line);
    line = line.replaceFirst(RegExp(r'^\s*'), '');
    line = line.replaceAll(RegExp(r'^[│├└─\-*·•+>\s]+'), '').trim();
    if (line.isEmpty) continue;

    // 跳过说明性行
    if (RegExp(r'^(输出|格式|示例|说明|硬性要求|注意|图中|整图)').hasMatch(line)) {
      continue;
    }

    // 名称 :: 注释（优先），兼容旧的 | 分隔
    String name = line;
    String note = '';
    final ci = line.indexOf('::');
    if (ci > 0) {
      name = line.substring(0, ci).trim();
      note = line.substring(ci + 2).trim();
    } else {
      final pi = line.indexOf('|');
      if (pi > 0) {
        name = line.substring(0, pi).trim();
        note = line.substring(pi + 1).trim();
      }
    }
    // 注释两侧的括号去掉，名称行尾残留的分隔符去掉
    note = note.replaceAll(RegExp(r'^[（(]'), '').replaceAll(RegExp(r'[）)]$'), '').trim();
    name = name.replaceAll(RegExp(r'[:：|｜]\s*$'), '').trim();

    if (name.isEmpty) continue;
    // 占位行直接丢
    if (_isPlaceholder(name)) continue;
    // 单字残片（如「第」「营」）多半是上一行被折断，不是独立单位
    if (name.length < 2) continue;
    // 过长的不是单位名
    if (name.length > 60) continue;

    entries.add((indent: indent, name: name, note: note));
  }

  if (entries.isEmpty) return null;

  final rootEntry = entries.first;
  final rootGuess = SidcRule.fromName(rootEntry.name);
  final root = OrbatNode(
    uniqueDesignation: rootEntry.name,
    additionalInformation: rootEntry.note,
    sidc: rootGuess.sidc,
  );

  final stack = <({int indent, OrbatNode node})>[
    (indent: rootEntry.indent, node: root)
  ];

  for (final e in entries.skip(1)) {
    while (stack.length > 1 && stack.last.indent >= e.indent) {
      stack.removeLast();
    }
    final parent = stack.last.node;

    OrbatNode? existing;
    for (final c in parent.children) {
      if (c.uniqueDesignation == e.name) {
        existing = c;
        break;
      }
    }

    final guess = SidcRule.fromName(e.name);
    final node = existing ??
        OrbatNode(
          uniqueDesignation: e.name,
          additionalInformation: e.note,
          sidc: guess.sidc,
        );
    if (existing == null) parent.children.add(node);
    stack.add((indent: e.indent, node: node));
  }

  return root;
}

/// 计算缩进宽度：空格算 1，tab 算 4，树形线/列表符号各算 2。
///
/// 列表符号必须计入——否则「- A」「  - B」会被算成同一层（都是 0），
/// 整个骨架解析就退化成扁平列表。
int _indentWidth(String line) {
  var n = 0;
  for (final ch in line.runes) {
    if (ch == 0x20) {
      n += 1;
    } else if (ch == 0x09) {
      n += 4;
    } else if (ch == 0x2502 || ch == 0x251C || ch == 0x2514) {
      // │ ├ └
      n += 2;
    } else if (ch == 0x2D || ch == 0x2A || ch == 0x2B) {
      // - * + （列表符号，视作一级缩进）
      n += 2;
    } else {
      break;
    }
  }
  return n;
}

/// 把多块识别结果合并成一棵树。
///
/// 总根的确定顺序：
///   1. 用户在补充说明里指定的 [hint.rootName]；
///   2. 「第一行中间列」（常规图，根通常画在顶部居中）；
///   3. 「第一行第一列」（超宽横向图）。
///
/// 挂载规则：
///   - 有 [hint.branches] 时，块根名能对上某个分支就挂到该分支下，否则挂到总根；
///   - **只在同一父节点下**做同名去重（名称 + SIDC 都相同才算重复）。
///     不能用全局名称索引——编制图里「指挥部」「行政基地核心」大量重名，
///     全局去重会把不同分支整个吞掉（实测 8 个司令部只剩 2 个）。
OrbatNode mergeTileTrees(
    List<({OrbatNode tree, ImageTile tile})> trees, {
  StructureHint? hint,
}) {
  if (trees.isEmpty) {
    throw ArgumentError('没有可合并的识别结果');
  }

  // ---- 有骨架：以骨架定结构，识别结果补名称/SIDC/注释 ----
  if (hint?.skeleton != null) {
    return _mergeWithSkeleton(trees, hint!.skeleton!);
  }

  if (trees.length == 1) return trees.first.tree;

  final first = trees.first.tile;
  final isWide = first.totalCols > first.totalRows * 2;

  // ---- 1) 选总根 ----
  var rootIdx = 0;
  if (hint?.rootName != null) {
    final want = hint!.rootName!;
    for (var i = 0; i < trees.length; i++) {
      final n = trees[i].tree.uniqueDesignation;
      if (n == want || n.contains(want) || want.contains(n)) {
        rootIdx = i;
        break;
      }
    }
  } else {
    // 按层级词选：旅 > 营 > 连。位置猜不可靠——实测 7864×2436 的图切 4 块后，
    // 最左块的根是「第1海军陆战营」，而真正的总根「苏联海军步兵旅」在第 2 块，
    // 按位置取最左会导致整棵树根节点错成营级。
    var bestScore = -1;
    for (var i = 0; i < trees.length; i++) {
      final score = _levelScore(trees[i].tree.uniqueDesignation);
      // 同分时取名称更短的：层级词一样时，短名更可能是纯层级总根
      //（「2nd Division」优于「The Citizen Division 2nd …」）。
      final shorter = score == bestScore &&
          score > 0 &&
          trees[i].tree.uniqueDesignation.length <
              trees[rootIdx].tree.uniqueDesignation.length;
      if (score > bestScore || shorter) {
        bestScore = score;
        rootIdx = i;
      }
    }
    // 都是 0 分（名字里没有层级词）时才退回位置启发式
    if (bestScore <= 0) {
      final midCol = (first.totalCols - 1) ~/ 2;
      final wantCol = isWide ? 0 : midCol;
      for (var i = 0; i < trees.length; i++) {
        final t = trees[i].tile;
        if (t.row == 0 && t.col == wantCol) {
          rootIdx = i;
          break;
        }
      }
    }
  }
  final root = trees[rootIdx].tree;

  // ---- 2) 挂载 ----
  void attach(OrbatNode parent, OrbatNode node, int depth) {
    if (depth > 10) return;

    // 同一父节点下同名即视为同一单位（不再要求 SIDC 一致——
    // 实测同一「炮兵营」在两块里被识别成不同 SIDC，会重复建两个分支）
    OrbatNode? dup;
    for (final c in parent.children) {
      if (c.uniqueDesignation == node.uniqueDesignation) {
        dup = c;
        break;
      }
    }

    if (dup != null) {
      // 字段级补全（0.3.1）：同名合并时残缺方的空注释/[?]注释/占位 SIDC
      // 用另一方补全——否则先挂载的残缺版会把完整版的注释挤丢。
      final noteBad = dup.additionalInformation.trim().isEmpty ||
          dup.additionalInformation.contains('[?]');
      final noteNewOk = node.additionalInformation.trim().isNotEmpty &&
          !node.additionalInformation.contains('[?]');
      final sidcBad = _isPlaceholderSidc(dup.sidc);
      final sidcNewOk = !_isPlaceholderSidc(node.sidc);
      if ((noteBad && noteNewOk) || (sidcBad && sidcNewOk)) {
        final merged = OrbatNode(
          uniqueDesignation: dup.uniqueDesignation,
          additionalInformation:
              noteBad && noteNewOk ? node.additionalInformation : dup.additionalInformation,
          sidc: sidcBad && sidcNewOk ? node.sidc : dup.sidc,
          children: dup.children,
        );
        parent.children.remove(dup);
        parent.children.add(merged);
        for (final c in node.children) {
          attach(merged, c, depth + 1);
        }
        return;
      }
      for (final c in node.children) {
        attach(dup, c, depth + 1);
      }
      return;
    }

    parent.children.add(node);
  }

  /// 在总根下找到（或按提示创建）某个二级分支节点
  OrbatNode branchNode(String name) {
    for (final c in root.children) {
      final n = c.uniqueDesignation;
      if (n == name || n.contains(name) || name.contains(n)) return c;
    }
    final created = OrbatNode(
      uniqueDesignation: name,
      additionalInformation: '',
      // 旅级司令部符号，按名称粗判层级
      sidc: _guessSidcForName(name),
    );
    root.children.add(created);
    return created;
  }

  for (var i = 0; i < trees.length; i++) {
    if (i == rootIdx) continue;
    final t = trees[i].tree;

    // 与总根是同一个单位的不同写法（如「海军步兵旅」vs「苏联海军步兵师」）
    // → 把子节点并进来，否则会多出一个和总根平级的分支，
    //   看起来就像"营和旅并列在顶层"。
    if (t.uniqueDesignation == root.uniqueDesignation ||
        _sameUnit(t.uniqueDesignation, root.uniqueDesignation)) {
      for (final c in t.children.toList()) {
        attach(root, c, 0);
      }
      continue;
    }

    // 块根与总根**同级**（0.3.1 新增）：同一单位被切块后的局部视图。
    // 实测澳军 2 师图切 4 块，三块的根都是师级（The Citizen Division /
    // 2nd Division HQ / 2nd Division），旧逻辑把它们整棵并列挂到总根下，
    // 产图上出现两个平级的师，且同一旅的残缺版和完整版分属不同父节点
    // 无法合并。此处直接提升其子节点到总根，跳过块根本身。
    final tScore = _levelScore(t.uniqueDesignation);
    final rootScore = _levelScore(root.uniqueDesignation);
    if (tScore > 0 && tScore >= rootScore) {
      for (final c in t.children.toList()) {
        attach(root, c, 0);
      }
      continue;
    }

    // 有分支提示就按名字归位
    String? matched;
    for (final b in hint?.branches ?? const <String>[]) {
      final n = t.uniqueDesignation;
      if (n == b || n.contains(b) || b.contains(n)) {
        matched = b;
        break;
      }
    }

    if (matched != null) {
      final target = branchNode(matched);
      if (target.uniqueDesignation == t.uniqueDesignation) {
        for (final c in t.children.toList()) {
          attach(target, c, 0);
        }
      } else {
        attach(target, t, 0);
      }
    } else {
      attach(root, t, 0);
    }
  }

  return root;
}

/// SIDC 主实体段（10-15）全 0 视为占位（AI 没给出有效图标语义）
bool _isPlaceholderSidc(String s) {
  final body = s.length > 15 ? s.substring(10, 16) : '';
  return body.isEmpty || body == '000000';
}

/// 判断两个名字是否指同一个单位。
///
/// 去掉国别/序号前缀与层级后缀后比较，例如：
///   「苏联海军步兵师」→「海军步兵」
///   「海军步兵旅」    →「海军步兵」  → 视为同一单位
bool _sameUnit(String a, String b) {
  String norm(String s) {
    var t = s.trim();
    t = t.replaceAll(RegExp(r'^(苏联|俄罗斯|美国|中国|英国|法国|德国|日本)'), '');
    t = t.replaceAll(RegExp(r'^第[0-9一二三四五六七八九十]+'), '');
    t = t.replaceAll(RegExp(r'(方面军|集团军|军区|战区|师|旅|团|营|连|排|班|群|支队|大队)$'), '');
    return t.trim();
  }

  final na = norm(a);
  final nb = norm(b);
  if (na.length < 2 || nb.length < 2) return false;
  return na == nb;
}

/// 骨架 + 识别结果合并。
///
/// 骨架决定**结构和层级**（用户提供的，一定是对的），
/// 识别结果负责**填充**：
///   - 用识别到的 SIDC / 注释覆盖骨架节点（SIDC 比按名字猜的准）；
///   - 识别到的下属单位若骨架里没有，挂到对应父节点下；
///   - 完全没被吸收的识别结果，挂到根下并标注「未匹配骨架」，便于人工归类。
OrbatNode _mergeWithSkeleton(
    List<({OrbatNode tree, ImageTile tile})> trees, OrbatNode skeleton) {
  // 1) 识别结果按名称建索引
  //    同名节点在不同块里可能一个只有名字、一个有完整下属，
  //    必须保留**子节点最多**的那份，否则会丢掉营下的连。
  final info = <String, OrbatNode>{};
  void indexAll(OrbatNode n) {
    final existing = info[n.uniqueDesignation];
    if (existing == null || n.children.length > existing.children.length) {
      info[n.uniqueDesignation] = n;
    }
    for (final c in n.children) {
      indexAll(c);
    }
  }

  for (final e in trees) {
    indexAll(e.tree);
  }

  // 已被吸收的名称（用于最后找漏网）
  final consumed = <String>{};

  void markConsumed(OrbatNode n) {
    consumed.add(n.uniqueDesignation);
    for (final c in n.children) {
      markConsumed(c);
    }
  }

  // 2) 按骨架重建
  OrbatNode build(OrbatNode skel) {
    consumed.add(skel.uniqueDesignation);
    final src = _lookupLoose(info, skel.uniqueDesignation);

    final children = <OrbatNode>[];
    for (final c in skel.children) {
      children.add(build(c));
    }

    // 识别结果里的额外下属（骨架没写到的）
    if (src != null) {
      for (final c in src.children) {
        final name = c.uniqueDesignation;
        final inSkeleton = skel.children.any((s) =>
            s.uniqueDesignation == name ||
            s.uniqueDesignation.contains(name) ||
            name.contains(s.uniqueDesignation));
        final alreadyBuilt = children.any((b) =>
            b.uniqueDesignation == name ||
            b.uniqueDesignation.contains(name) ||
            name.contains(b.uniqueDesignation));
        if (inSkeleton || alreadyBuilt) continue;

        // 整棵并入，并把子树标记为已吸收，避免末了又被当漏网挂一遍
        markConsumed(c);
        children.add(c);
      }
    }

    return OrbatNode(
      uniqueDesignation: skel.uniqueDesignation,
      additionalInformation:
          (src != null && src.additionalInformation.isNotEmpty)
              ? src.additionalInformation
              : skel.additionalInformation,
      // 识别到的 SIDC 比骨架按名字猜的更准
      sidc: (src != null && src.sidc.length == 30) ? src.sidc : skel.sidc,
      children: children,
    );
  }

  final root = build(skeleton);

  // 3) 漏网的识别结果：先试着并到已有同名节点，实在没有才挂根下
  OrbatNode? findLoose(OrbatNode from, String name) {
    if (from.uniqueDesignation == name ||
        from.uniqueDesignation.contains(name) ||
        name.contains(from.uniqueDesignation)) {
      return from;
    }
    for (final c in from.children) {
      final hit = findLoose(c, name);
      if (hit != null) return hit;
    }
    return null;
  }

  void collectLeftovers(OrbatNode n) {
    if (consumed.contains(n.uniqueDesignation)) {
      for (final c in n.children) {
        collectLeftovers(c);
      }
      return;
    }

    // 已有同名/近似节点：把子节点并进去，不要再建一个重复分支
    final target = findLoose(root, n.uniqueDesignation);
    if (target != null) {
      consumed.add(n.uniqueDesignation);
      for (final c in n.children) {
        final dup = target.children.any((x) =>
            x.uniqueDesignation == c.uniqueDesignation ||
            x.uniqueDesignation.contains(c.uniqueDesignation) ||
            c.uniqueDesignation.contains(x.uniqueDesignation));
        if (!dup) target.children.add(c);
      }
      return;
    }

    // 没有同名节点：按名称核心词找最合适的父节点
    // 例：「第1反坦克连」的核心是「反坦克」→ 挂到骨架里的「反坦克营」下
    final core = _coreKeyword(n.uniqueDesignation);
    if (core.length >= 2) {
      final parent = _findByCore(root, core, root);
      if (parent != null) {
        consumed.add(n.uniqueDesignation);
        final dup = parent.children.any(
            (x) => x.uniqueDesignation == n.uniqueDesignation);
        if (!dup) parent.children.add(n);
        return;
      }
    }

    consumed.add(n.uniqueDesignation);
    root.children.add(OrbatNode(
      uniqueDesignation: n.uniqueDesignation,
      additionalInformation: '未匹配骨架',
      sidc: n.sidc,
      children: n.children,
    ));
  }

  for (final e in trees) {
    collectLeftovers(e.tree);
  }

  return root;
}

/// 宽松查找：先精确，再按包含关系取最接近的
OrbatNode? _lookupLoose(Map<String, OrbatNode> index, String name) {
  final exact = index[name];
  if (exact != null) return exact;

  OrbatNode? best;
  var bestDiff = 1 << 30;
  for (final e in index.entries) {
    final k = e.key;
    if (k.contains(name) || name.contains(k)) {
      final diff = (k.length - name.length).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = e.value;
      }
    }
  }
  return best;
}

/// 提取名称的核心词：去掉「第N」前缀、括号内容、层级后缀
String _coreKeyword(String name) {
  return name
      .replaceAll(RegExp(r'[（(].*?[）)]'), '')
      .replaceAll(RegExp(r'^第[0-9０-９一二三四五六七八九十百]+'), '')
      .replaceAll(RegExp(r'(司令部|指挥部|分队|连|排|营|团|旅|师|班|组|部)$'), '')
      .trim();
}

/// 在树里找名称包含该核心词的节点（跳过根自身）
OrbatNode? _findByCore(OrbatNode node, String core, OrbatNode root) {
  if (!identical(node, root) &&
      node.uniqueDesignation != core &&
      node.uniqueDesignation.contains(core)) {
    return node;
  }
  for (final c in node.children) {
    final hit = _findByCore(c, core, root);
    if (hit != null) return hit;
  }
  return null;
}

bool _isPlaceholder(String name) {
  final t = name.trim();
  if (t.isEmpty) return true;
  const markers = ['无法识别', '无法辨认', '看不清', '名称被遮蔽', '未识别', '未知单位'];
  if (markers.any(t.contains)) return true;
  return t == '未知' || t == '?';
}

///
/// 先剔除军种词（海军/陆军/空军…），否则「海军步兵旅」里的「海军」会被误判成军级。
/// 以「部/指挥部/司令部」结尾的多是下属的指挥机构，降权避免被当成总根
/// （但「总指挥部」例外，它本身可能就是根）。
int _levelScore(String name) {
  // 「巴基斯坦陆军 / 美国海军 / 俄罗斯陆军」这类**国名+军种**是全军总称，
  // 是最高层级的总根。下面剔除军种词的规则会把「陆军」去掉变成光秃秃的国名
  // （得分 0），导致总根被误选成它下面的「第1军」。这里先识别并直接返回最高分。
  if (RegExp(r'(斯坦|联邦|国|帝国|王国|苏维埃|人民)(海军|陆军|空军|武装部队)')
          .hasMatch(name) ||
      RegExp(r'^(美国|俄罗斯|苏联|中国|英国|法国|德国|日本|印度|巴基斯坦|伊朗)'
              r'(海军|陆军|空军|武装部队)')
          .hasMatch(name)) {
    return 100;
  }
  final n = name.replaceAll(
      RegExp(r'海军|陆军|空军|火箭军|军种|军事|集团军群'), '');

  int score = 0;
  if (n.contains('方面军') || n.contains('战区') || n.contains('军区')) {
    score = 90;
  } else if (n.contains('集团军')) {
    score = 80;
  } else if (n.contains('军')) {
    score = 70;
  } else if (n.contains('师')) {
    score = 60;
  } else if (n.contains('旅')) {
    score = 50;
  } else if (n.contains('团') || n.contains('群')) {
    score = 40;
  } else if (n.contains('营')) {
    score = 30;
  } else if (n.contains('连')) {
    score = 20;
  } else if (n.contains('排') || n.contains('班') || n.contains('组')) {
    score = 10;
  }

  if (score > 0 &&
      !name.contains('总指挥部') &&
      (name.endsWith('部') || name.contains('指挥部') || name.contains('司令部'))) {
    score = score ~/ 3;
  }

  // 英文军制图（澳/美/英式）：层级词判定与中文同构（0.3.1 新增）。
  // 实测澳军图「The Citizen Division 2nd …」「2nd Division HQ」「2nd Division」
  // 三个块根全是 0 分，导致总根选择退回位置启发式、三根并列挂载，
  // 同一旅的残缺版和完整版落在不同父节点下无法去重。
  if (score == 0) {
    if (RegExp(r'Division(?!al)').hasMatch(n)) {
      score = 60;
    } else if (RegExp(r'Brigade|\bBde\b').hasMatch(n)) {
      score = 50;
    } else if (RegExp(r'Regiment').hasMatch(n)) {
      score = 40;
    } else if (RegExp(r'Battalion|\bBn\b').hasMatch(n)) {
      score = 30;
    } else if (RegExp(r'Company|\bCoy\b').hasMatch(n)) {
      score = 20;
    } else if (RegExp(r'\bCorps\b').hasMatch(n)) {
      score = 70;
    }
  }
  return score;
}

/// 按名称粗判层级，给骨架节点一个合理的 SIDC
/// （识别结果里有同名节点时，会用识别到的 SIDC 覆盖它）
String _guessSidcForName(String name) {
  String echelon = '18'; // 默认旅
  if (name.contains('方面军') || name.contains('战区')) {
    echelon = '25';
  } else if (name.contains('集团军')) {
    echelon = '23';
  } else if (name.contains('师')) {
    echelon = '21';
  } else if (name.contains('旅')) {
    echelon = '18';
  } else if (name.contains('团')) {
    echelon = '17';
  } else if (name.contains('营')) {
    echelon = '16';
  } else if (name.contains('连')) {
    echelon = '15';
  } else if (name.contains('排')) {
    echelon = '14';
  }
  // 1303 + 符号集10 + 00 + 梯队 + 实体110000 + 类型00 + 机动00 + 扇区00 + 保留8
  return '13031000$echelon' '110000' '000000' '00000000';
}

/// 从 JSON 字符串还原树（供手工编辑后重新出图）
OrbatNode? parseTreeJson(String jsonText) {
  try {
    final map = jsonDecode(jsonText) as Map<String, dynamic>;
    final tree = OrbatNode.fromJson(map);
    return tree.count > 0 ? tree : null;
  } catch (_) {
    return null;
  }
}
