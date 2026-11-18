/// 图片预处理 —— 把编制图变成"模型真正看得清"的图块
///
/// 为什么需要这一步（实测数据）：
///   DeepSeek 的图片输入对任何尺寸都只折算成约 **1020 个 token**。
///   把一张 7614×7686、上千节点的编制图整张传进去，模型看到的是极小的缩略图，
///   文字全糊，只能靠猜——实测它把「巴西陆军」答成「XXX公司」。
///   切成 3×3、每块缩到 1536 像素后，同一模型能准确读出
///   「巴西陆军 / 亚马逊军事司令部 / 第1丛林步兵旅」等名称。
///
/// 所以策略是：**尺寸超过阈值就切片，每块控制在模型能看清的范围内**。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 一个待发送的图块
class ImageTile {
  /// PNG 字节
  final Uint8List png;

  /// 在网格中的位置（单块时为 0,0）
  final int row;
  final int col;
  final int totalRows;
  final int totalCols;

  /// 该块覆盖的原图像素范围（用于日志）
  final int srcX, srcY, srcW, srcH;

  ImageTile({
    required this.png,
    required this.row,
    required this.col,
    required this.totalRows,
    required this.totalCols,
    required this.srcX,
    required this.srcY,
    required this.srcW,
    required this.srcH,
  });

  bool get isSingle => totalRows == 1 && totalCols == 1;

  String get label => isSingle
      ? '整图'
      : '第${row + 1}行第${col + 1}列（共${totalRows}×${totalCols}）';

  int get sizeKb => (png.length / 1024).round();
}

/// 切片计划
class TilePlan {
  final int srcWidth, srcHeight;
  final List<ImageTile> tiles;

  TilePlan({
    required this.srcWidth,
    required this.srcHeight,
    required this.tiles,
  });

  bool get isTiled => tiles.length > 1;

  String get summary => isTiled
      ? '原图 ${srcWidth}×$srcHeight，切为 ${tiles.length} 块分别识别'
      : '原图 ${srcWidth}×$srcHeight，单块识别';
}

/// 预处理参数
class TileOptions {
  /// 像素总数不超过这个值就整张发（实测 7864×2436 = 1900 万像素整张发，
  /// 一次调用就能 1:1 复刻 55 个节点的编制图）
  final int singleMaxPixels;

  /// 密集方形图阈值：长边超过此值且宽高比 < [denseAspectMax] 时强制横切
  final int denseLongSide;

  /// 密集图宽高比上限（小于此值视为"接近方形"）
  final double denseAspectMax;

  /// 整张识别时的长边上限
  final int singleMaxLongSide;

  /// 切片后每块的长边
  final int tileMaxLongSide;

  /// 每块覆盖的原图长边（实测 2600 左右时，缩到 1536 仍有 60%，文字清晰）
  final int tileSourceSpan;

  /// 相邻块的重叠比例，避免单位正好被切在边界
  final double overlap;

  const TileOptions({
    this.singleMaxPixels = 30000000, // 3000 万像素
    /// 密集方形图阈值：长边超过此值、且宽高比小于 [denseAspectMax] 的图，
    /// 像素数虽未超 [singleMaxPixels]，但文字密集到整图看不清，必须横切。
    /// 实测巴基斯坦陆军图 4137×2871（1188 万像素）整图发送时，模型狂写
    /// 196 列「看不清」耗尽 64000 token、耗时 248 秒仍无 JSON；横切 1×4 后
    /// 每块 2 秒即准确读出「第5军/第16步兵师/第10军…」。
    this.denseLongSide = 4000,
    /// 宽高比小于此值视为"接近方形的密集图"（横切不纵切）
    this.denseAspectMax = 1.8,
    // 整图不缩放：实测把 7864 宽的图缩到 4096 后，旅直属单位的层级判断会出错
    // （12 个二级变 8 个）。原图直接传，API 自己会做折算。
    this.singleMaxLongSide = 16384,
    this.tileMaxLongSide = 1536,
    this.tileSourceSpan = 2600,
    // 12% 重叠：实测比 6% 好，但继续加大到 18% 反而变差（块变宽压缩更多）
    this.overlap = 0.12,
  });
}

/// 分析图片并生成待发送的图块。
///
/// 注意：会完整解码原图，超大图（>1 亿像素）内存占用较高。
/// 调用方应放在 isolate 里跑，避免卡住 UI。
TilePlan prepareTiles(Uint8List bytes, {TileOptions options = const TileOptions()}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('无法解码图片（格式不支持或文件损坏）');
  }

  final w = decoded.width;
  final h = decoded.height;
  final longSide = w > h ? w : h;

  // ---- 情况一：整张发 ----
  // 判据用**像素总数**而不是长边：实测 7864×2436（1900 万像素）整张发出去，
  // 模型仍能准确读出全部 55 个单位，一次调用即可；而 35168×2952（1 亿像素）
  // 整张发会糊成一片，必须切片。
  //
  // 但像素数不能单独判断"看不看得清"：巴基斯坦陆军图 4137×2871（1188 万像素、
  // 宽高比 1.44）单位极多、字极小，整图发会导致模型输出爆炸（详见 denseLongSide 注释）。
  // 补充判据：接近方形（宽高比 < 3）且长边超 4000 的密集图，强制走横切。
  // 苏联图 7864×2436 宽高比 3.2 > 3，仍走整图，保持原有 1:1 效果。
  final aspect = w / h;
  final denseNeedSlice =
      longSide > options.denseLongSide && aspect < options.denseAspectMax;
  if (w * h <= options.singleMaxPixels && !denseNeedSlice) {
    final target = _scaleTo(decoded, options.singleMaxLongSide);
    return TilePlan(
      srcWidth: w,
      srcHeight: h,
      tiles: [
        ImageTile(
          png: Uint8List.fromList(img.encodePng(target, level: 6)),
          row: 0,
          col: 0,
          totalRows: 1,
          totalCols: 1,
          srcX: 0,
          srcY: 0,
          srcW: w,
          srcH: h,
        ),
      ],
    );
  }

  // ---- 情况二：切片 ----
  //
  // 关键：**超宽图只横切，不纵切**。
  // 编制图常被横向展开成很宽的条带（实测 35168×2952，宽高比 12:1），
  // 每个"列"是完整的一条分支。若再纵向切成两半，分支会被拦腰截断，
  // 合并时层级关系就彻底乱了（实测切 2×12 时 22 个分支平铺在根下）。
  // 判据：
  //   - 超宽图（宽高比 > 4）：只横切，不纵切（每列是完整分支）
  //   - 密集方形图（长边 > denseLongSide 且宽高比 < 3）：也只横切——
  //     这类图同样是"并列纵列"结构，纵切会把细长列拦腰截断导致合并层级错乱。
  //     巴基斯坦图实测 1×4 横切每块 2 秒读准，2×2 切则丢内容。
  //   - 常规图：横纵都切
  final onlyHorizontal = aspect > 4 || denseNeedSlice;
  final rows = onlyHorizontal
      ? 1
      : (h / options.tileSourceSpan).ceil().clamp(1, 12);
  // 密集图每块跨度调小（约 600），让细长列文字更清晰
  // 实测 600(1×7) 会让每块变成窄长条，模型更易幻觉且耗时反而暴涨（459s）；
  // 1100(1×4) 是这张图的最佳切法（每块宽高比适中，识别最稳）。
  final effectiveSpan = denseNeedSlice ? 1100 : options.tileSourceSpan;
  final cols = (w / effectiveSpan).ceil().clamp(1, 14);
  final tiles = <ImageTile>[];

  final baseTileW = (w / cols).ceil();
  final baseTileH = (h / rows).ceil();
  final ovW = (baseTileW * options.overlap).round();
  final ovH = (baseTileH * options.overlap).round();

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final x0 = (c * baseTileW - ovW).clamp(0, w - 1);
      final y0 = (r * baseTileH - ovH).clamp(0, h - 1);
      final x1 = ((c + 1) * baseTileW + ovW).clamp(x0 + 1, w);
      final y1 = ((r + 1) * baseTileH + ovH).clamp(y0 + 1, h);

      final crop = img.copyCrop(decoded,
          x: x0, y: y0, width: x1 - x0, height: y1 - y0);
      final scaled = _scaleTo(crop, options.tileMaxLongSide);

      tiles.add(ImageTile(
        png: Uint8List.fromList(img.encodePng(scaled, level: 6)),
        row: r,
        col: c,
        totalRows: rows,
        totalCols: cols,
        srcX: x0,
        srcY: y0,
        srcW: x1 - x0,
        srcH: y1 - y0,
      ));
    }
  }

  return TilePlan(srcWidth: w, srcHeight: h, tiles: tiles);
}

/// 等比缩放到指定长边；已经更小则不放大
img.Image _scaleTo(img.Image src, int maxLongSide) {
  final longSide = src.width > src.height ? src.width : src.height;
  if (longSide <= maxLongSide) return src;
  final ratio = maxLongSide / longSide;
  return img.copyResize(
    src,
    width: (src.width * ratio).round(),
    height: (src.height * ratio).round(),
    interpolation: img.Interpolation.average,
  );
}

/// 按网格坐标从图片中裁出单个图块，写成临时 PNG 文件。
///
/// 用于 CLI 的 `retry-tile`：某个块识别失败时，只重跑那一块而不用整张重来。
/// 裁切逻辑与 [prepareTiles] 保持一致（含重叠区），确保重跑的块和原流程等价。
File prepareTileFromFile(
  File source,
  int row,
  int col,
  int totalRows,
  int totalCols, {
  TileOptions options = const TileOptions(),
}) {
  final decoded = img.decodeImage(source.readAsBytesSync());
  if (decoded == null) throw const FormatException('无法解码图片');

  final w = decoded.width;
  final h = decoded.height;
  final baseTileW = (w / totalCols).ceil();
  final baseTileH = (h / totalRows).ceil();
  final ovW = (baseTileW * options.overlap).round();
  final ovH = (baseTileH * options.overlap).round();

  final x0 = (col * baseTileW - ovW).clamp(0, w - 1);
  final y0 = (row * baseTileH - ovH).clamp(0, h - 1);
  final x1 = ((col + 1) * baseTileW + ovW).clamp(x0 + 1, w);
  final y1 = ((row + 1) * baseTileH + ovH).clamp(y0 + 1, h);

  final crop =
      img.copyCrop(decoded, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  final scaled = _scaleTo(crop, options.tileMaxLongSide);

  final out = File('${Directory.systemTemp.path}/orbat_retry_tile_'
      '${row}_${col}_${DateTime.now().millisecondsSinceEpoch}.png');
  out.writeAsBytesSync(img.encodePng(scaled, level: 6));
  return out;
}
