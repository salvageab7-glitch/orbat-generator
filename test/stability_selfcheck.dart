/// 稳定性纯函数自检：不联网、不调用 API、不启动浏览器。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:orbat_core/ai/deepseek_client.dart';
import 'package:orbat_core/render/renderer.dart';

Future<void> main() async {
  int pass = 0;
  int fail = 0;
  void check(String name, bool condition) {
    if (condition) {
      pass++;
      print('  PASS  $name');
    } else {
      fail++;
      print('  FAIL  $name');
    }
  }

  print('=== 1. Retry-After 解析 ===');
  check('秒数 7', parseRetryAfter('7') == const Duration(seconds: 7));
  check('空值 null', parseRetryAfter(null) == null);
  check('非法值 null', parseRetryAfter('not-a-date') == null);
  check(
    'HTTP 日期',
    parseRetryAfter(
          'Wed, 21 Oct 2015 07:28:00 GMT',
          now: DateTime.utc(2015, 10, 21, 7, 27, 0),
        ) ==
        const Duration(seconds: 60),
  );

  print('=== 2. 状态码分类 ===');
  check('400 永久失败', isPermanentError(classifyStatus(400)));
  check('401 永久失败', isPermanentError(classifyStatus(401)));
  check('402 永久失败', isPermanentError(classifyStatus(402)));
  check('403 永久失败', isPermanentError(classifyStatus(403)));
  check('429 可重试', !isPermanentError(classifyStatus(429)));
  check('500 可重试', !isPermanentError(classifyStatus(500)));
  check('408 视为超时', classifyStatus(408) == DeepSeekErrorKind.timeout);

  print('=== 3. 退避策略 ===');
  final Duration d1 = retryDelayFor(1, random: Random(1));
  final Duration d2 = retryDelayFor(2, random: Random(1));
  check('第1次 1.0-1.25s', d1.inMilliseconds >= 1000 && d1.inMilliseconds < 1250);
  check('第2次 3.0-3.25s', d2.inMilliseconds >= 3000 && d2.inMilliseconds < 3250);
  check(
    'Retry-After 优先',
    retryDelayFor(1, retryAfter: const Duration(seconds: 5)) ==
        const Duration(seconds: 5),
  );

  print('=== 4. 动态超时 ===');
  check('0 像素 → 60s', dynamicTimeoutFor(0).inSeconds == 60);
  check('1MP → 60s', dynamicTimeoutFor(1000000).inSeconds == 60);
  check('4MP → 90s', dynamicTimeoutFor(4000000).inSeconds == 90);
  check('8MP → 120s 上限', dynamicTimeoutFor(8000000).inSeconds == 120);

  print('=== 5. PNG 校验 ===');
  final List<int> png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  check('1x1 PNG 有效', isValidPngBytes(png1x1));
  check('随机字节无效', !isValidPngBytes(<int>[1, 2, 3, 4]));

  print('=== 6. PNG 空白检测 ===');
  final img.Image blank = img.Image(width: 300, height: 200);
  img.fill(blank, color: img.ColorRgb8(255, 255, 255));
  final Uint8List blankPng = img.encodePng(blank);
  check('空白 PNG 被拒', !inspectPngQuality(blankPng).ok);

  final img.Image drawn = img.Image(width: 300, height: 200);
  img.fill(drawn, color: img.ColorRgb8(255, 255, 255));
  img.drawLine(
    drawn,
    x1: 0,
    y1: 0,
    x2: 299,
    y2: 199,
    color: img.ColorRgb8(0, 0, 0),
    thickness: 4,
  );
  check('有内容 PNG 通过', inspectPngQuality(img.encodePng(drawn)).ok);

  print('=== 7. 原子写 ===');
  final Directory tmp = Directory.systemTemp.createTempSync('orbat_stability_');
  try {
    final String p = '${tmp.path}${Platform.pathSeparator}atomic.bin';
    await writeBytesAtomic(p, <int>[1, 2, 3, 4]);
    check('字节写入', File(p).readAsBytesSync().join(',') == '1,2,3,4');

    final String s = '${tmp.path}${Platform.pathSeparator}atomic.txt';
    await writeStringAtomic(s, 'hello');
    check('文本写入', File(s).readAsStringSync() == 'hello');

    final List<File> leftovers = tmp
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.contains('.tmp-'))
        .toList();
    check('无 .tmp 残留', leftovers.isEmpty);
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n=== 结果: PASS $pass / FAIL $fail ===');
  if (fail > 0) exitCode = 1;
}
