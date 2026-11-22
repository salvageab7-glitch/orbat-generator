/// 安卓端出图（方案 A）—— 内置 WebView 加载 spatialillusions.com 线上站点渲染
///
/// 复刻 runtime/render_orbat.js（Windows/CDP 版）的全部步骤：
///   1. 打开站点，等待初始化（#openOrbat 出现，最长 120s）
///   2. 把编制 JSON 注入 #openOrbat 文件输入框（DataTransfer + File 模拟选文件）
///   3. 等待 #orbat-svg 里出现本图根节点名（45s，重试 2 次）
///   4. 抠出独立 SVG（清 body、白底 holder、按 viewBox 设宽高）→ 保存 .svg
///   5. canvas 光栅化 PNG（scale 倍、白底可选、viewBox 负偏移处理）→ 保存 .png
///
/// 与 CDP 版的关键差异：
///   - Android WebView 的 evaluateJavascript **不返回 Promise**，所以所有异步
///     JS（图片加载）都先把结果落到 window.__orbat* 全局变量，再由 Dart 侧轮询读取。
///   - 注入文件不走 DOM.setFileInputFiles（WebView 没有 CDP），改用页面上下文
///     构造 File + DataTransfer 后触发 change 事件——站点只读 files[0] 内容，行为一致。
///
/// 设计原则不变：**PNG 只能由线上站点渲染产出**，本模块只负责加载、注入、导出。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';

import 'renderer.dart';

/// 渲染任务参数
class WebViewRenderJob {
  /// 7 键归一化后的完整树 JSON（与 Windows 出图同一份 normalizeTreeJson 产物）
  final String normalizedJson;

  /// 输出基名（不含扩展名），会产出 `.svg` 与 `.png`
  final String outputBase;

  /// PNG 输出倍率（默认 2 = 2x 高清）
  final int scale;

  /// PNG 是否白色背景（false = 透明底）
  final bool whiteBackground;

  /// 整体超时（与 Windows 端一致的 5 分钟）
  final Duration timeout;

  const WebViewRenderJob({
    required this.normalizedJson,
    required this.outputBase,
    this.scale = 2,
    this.whiteBackground = true,
    this.timeout = const Duration(minutes: 5),
  });
}

/// 渲染执行器。所有方法都需要一个已创建的 [WebViewController]。
class WebViewRenderer {
  static const _siteUrl = 'https://spatialillusions.com/unitgenerator';

  /// 执行完整渲染流程。
  ///
  /// 前置条件：controller 已创建但**不要**预先 loadRequest——由本方法控制加载，
  /// 以便完整记录各阶段日志。
  static Future<RenderResult> render(
    WebViewController controller,
    WebViewRenderJob job, {
    void Function(String line)? onLog,
  }) async {
    final sw = Stopwatch()..start();

    void log(String line) => onLog?.call(line);

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
      );
    }

    // 根节点名（等画布出现根名才算导入成功——与 Windows 脚本同一判据）
    String rootName = '';
    try {
      rootName =
          (jsonDecode(job.normalizedJson)['options']['uniqueDesignation'] ?? '')
              .toString();
    } catch (_) {}

    Future<bool> evalBool(String expr, {Duration? timeout, Duration step = const Duration(milliseconds: 500)}) async {
      final deadline = DateTime.now().add(timeout ?? const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        try {
          final r = await controller.runJavaScriptReturningResult(expr);
          if (r == true || r.toString() == 'true') return true;
        } catch (_) {}
        await Future<void>.delayed(step);
      }
      return false;
    }

    try {
      // ---- 1) 打开站点并等待初始化 ----
      log('[stage] 打开渲染站点');
      await controller.loadRequest(Uri.parse(_siteUrl));
      log('[stage] 等待站点初始化（最长 120s）');
      final ready = await evalBool(
        "!!document.querySelector('#openOrbat')",
        timeout: const Duration(seconds: 120),
      );
      if (!ready) {
        return finish(
          ok: false,
          error: '等待站点初始化超时：120s 内未出现 #openOrbat。'
              '请确认设备能访问 spatialillusions.com（检查网络/代理）后重试。',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 4));

      // ---- 2) 导入 JSON（最多 2 次）----
      final jsonLiteral = jsonEncode(job.normalizedJson); // JSON 字符串字面量，JS 兼容
      bool imported = false;
      String? injectErr;
      for (int attempt = 1; attempt <= 2 && !imported; attempt++) {
        log('[stage] 导入编制数据（第 $attempt 次）');
        // 异步站点脚本消费 change 事件需要时间，先清掉旧标记再注入
        try {
          await controller.runJavaScript(
              'window.__orbatPng=null; window.__orbatSvg=null; window.__orbatErr=null;');
        } catch (_) {}

        try {
          await controller.runJavaScript('''
            window.__orbatJson = $jsonLiteral;
          ''');
        } catch (e) {
          injectErr = '注入 JSON 失败: $e';
          log('[import] $injectErr');
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }

        final injected = await evalBool('''
          (() => {
            try {
              const data = window.__orbatJson;
              if (!data) return false;
              const dt = new DataTransfer();
              dt.items.add(new File([data], "orbat.json", { type: "application/json" }));
              const input = document.querySelector('#openOrbat');
              if (!input) return false;
              input.files = dt.files;
              input.dispatchEvent(new Event('change', { bubbles: true }));
              return true;
            } catch (e) {
              window.__orbatErr = String(e);
              return false;
            }
          })()
        ''', timeout: const Duration(seconds: 15), step: const Duration(seconds: 1));
        if (!injected) {
          try {
            final err = await controller.runJavaScriptReturningResult(
                'window.__orbatErr || "null"');
            injectErr = '模拟文件选择未生效: $err';
          } catch (_) {
            injectErr = '模拟文件选择未生效';
          }
          log('[import] 第 $attempt 次导入未生效：$injectErr');
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }

        // ---- 3) 等待画布出现根名（45s）----
        log('[stage] 等待画布渲染');
        final rootLit = jsonEncode(rootName);
        final rendered = await evalBool('''
          (() => {
            const s = document.querySelector('#orbat-svg');
            if (!s || !s.querySelectorAll('*').length) return false;
            const want = $rootLit;
            return !want || s.textContent.includes(want);
          })()
        ''', timeout: const Duration(seconds: 45));
        if (rendered) {
          imported = true;
        } else {
          log('[import] 第 $attempt 次导入未生效：画布 45s 内未出现本图内容');
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      if (!imported) {
        return finish(
          ok: false,
          error: '导入编制 JSON 后 #orbat-svg 里没有出现本图内容（站点未就绪）。'
              '${injectErr == null ? '' : ' 最后一次原因：$injectErr'}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // ---- 4) 统计渲染结果（尽力而为，不阻塞）----
      try {
        final stat = await controller.runJavaScriptReturningResult('''
          (() => {
            const svg = document.querySelector('#orbat-svg');
            if (!svg) return 'no svg';
            return JSON.stringify({
              elements: svg.querySelectorAll('*').length,
              viewBox: svg.getAttribute('viewBox'),
            });
          })()
        ''');
        log('SVG_STAT ${_unwrap(stat)}');
      } catch (_) {}

      // ---- 5) 抠出独立 SVG 并保存 ----
      final bgLiteral = job.whiteBackground ? "'#ffffff'" : "'transparent'";
      final vbStr = await controller.runJavaScriptReturningResult('''
        (() => {
          const svg = document.querySelector('#orbat-svg');
          const vb = (svg.getAttribute('viewBox') || '0 0 100 100')
              .trim().split(/[\\s,]+/).map(Number);
          const src = svg.outerHTML;
          document.body.innerHTML = '';
          document.body.style.margin = '0';
          const bg = $bgLiteral;
          document.body.style.background = bg;
          document.documentElement.style.background = bg;
          const holder = document.createElement('div');
          holder.style.cssText = 'position:absolute;left:0;top:0;background:' + bg + ';';
          holder.innerHTML = src;
          document.body.appendChild(holder);
          const s2 = holder.querySelector('svg');
          s2.setAttribute('width', vb[2]);
          s2.setAttribute('height', vb[3]);
          s2.style.width = vb[2] + 'px';
          s2.style.height = vb[3] + 'px';
          s2.style.display = 'block';
          return JSON.stringify(vb);
        })()
      ''');
      // Android WebView 返回值可能是「JSON 字符串再包一层引号」的形式，
      // 逐层解包到真正的数组/对象/字符串为止
      final vb = (_unwrap(vbStr) as List);
      // 元素可能是 num 或数字字符串（不同 WebView 实现行为不一）
      final w = (num.tryParse(vb[2].toString()) ?? 100).ceil();
      final h = (num.tryParse(vb[3].toString()) ?? 100).ceil();

      String? svgPath;
      final svgText = await controller.runJavaScriptReturningResult(
          "document.querySelector('body svg') ? document.querySelector('body svg').outerHTML : ''");
      final svgOut = _unwrap(svgText)?.toString() ?? '';
      if (svgOut.length > 100) {
        log('[stage] 导出 SVG');
        svgPath = '${job.outputBase}.svg';
        await File(svgPath).writeAsString(svgOut, encoding: utf8, flush: true);
        log('SVG_FILE $svgPath');
      } else {
        log('[svg] SVG 内容过短，跳过导出');
      }

      // ---- 6) canvas 光栅化 PNG（异步结果落全局变量后轮询读取）----
      log('[stage] 导出 PNG');
      await controller.runJavaScript('''
        (async () => {
          window.__orbatPng = null;
          window.__orbatErr = null;
          try {
            const svgEl = document.querySelector('body svg');
            if (!svgEl) throw new Error('no svg for rasterize');
            const vb = (svgEl.getAttribute('viewBox') || '0 0 $w $h')
                .trim().split(/[\\s,]+/).map(Number);
            const sx = vb[0] || 0, sy = vb[1] || 0, sw = vb[2] || $w, sh = vb[3] || $h;
            const clone = svgEl.cloneNode(true);
            clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
            clone.setAttribute('width', sw);
            clone.setAttribute('height', sh);
            clone.removeAttribute('style');
            const xml = new XMLSerializer().serializeToString(clone);
            const blob = new Blob([xml], {type: 'image/svg+xml;charset=utf-8'});
            const url = URL.createObjectURL(blob);
            const canvas = document.createElement('canvas');
            canvas.width = Math.ceil(sw * ${job.scale});
            canvas.height = Math.ceil(sh * ${job.scale});
            const ctx = canvas.getContext('2d');
            ${job.whiteBackground ? "ctx.fillStyle = '#ffffff'; ctx.fillRect(0,0,canvas.width,canvas.height);" : ""}
            const img = new Image();
            await new Promise((resolve, reject) => {
              img.onload = resolve;
              img.onerror = (e) => reject(new Error('svg image load failed: ' + e));
              img.src = url;
            });
            ctx.drawImage(img, -sx * ${job.scale}, -sy * ${job.scale}, canvas.width, canvas.height);
            URL.revokeObjectURL(url);
            window.__orbatPng = canvas.toDataURL('image/png');
          } catch (e) {
            window.__orbatErr = String(e);
            window.__orbatPng = '';
          }
        })()
      ''');

      Object? pngVal;
      final pngDeadline =
          DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(pngDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          pngVal = _unwrap(await controller.runJavaScriptReturningResult(
              'window.__orbatPng === undefined ? "pending" : String(window.__orbatPng)'));
        } catch (_) {
          continue;
        }
        final s = pngVal?.toString() ?? '';
        if (s.isNotEmpty && s != 'pending' && s != 'null' && s != 'undefined') break;
      }
      final pngDataUrl = pngVal?.toString() ?? '';
      if (pngDataUrl.isEmpty ||
          pngDataUrl == 'null' ||
          pngDataUrl == 'pending' ||
          !pngDataUrl.startsWith('data:image/png')) {
        String? extra;
        try {
          final err = await controller.runJavaScriptReturningResult(
              'window.__orbatErr || "null"');
          extra = _unwrap(err)?.toString();
        } catch (_) {}
        return finish(
          ok: false,
          error: 'PNG 光栅化失败（60s 内未产出 dataURL）。$extra',
        );
      }
      final b64 = pngDataUrl.split(',')[1];
      final pngPath = '${job.outputBase}.png';
      await File(pngPath).writeAsBytes(
        base64.decode(b64),
        flush: true,
      );
      final pngFile = File(pngPath);
      if (pngFile.lengthSync() == 0) {
        return finish(ok: false, error: 'PNG 未生成或为空: $pngPath');
      }
      log('PNG_FILE $pngPath $w"x"$h @${job.scale}x = '
          '${w * job.scale}x${h * job.scale}');
      log('[stage] 完成');
      return finish(ok: true, png: pngPath, svg: svgPath);
    } catch (e) {
      log('[client] 异常: $e');
      return finish(ok: false, error: '出图异常：$e');
    }
  }

  /// 解包 Android WebView 的返回值。
  ///
  /// Android 的 evaluateJavascript 返回「JSON 序列化」的字符串：
  ///   - JS 数字 42      → Dart 收到 "42" 或 int 42（随实现版本）
  ///   - JS 数组 [1,2]   → Dart 收到 '[1,2]'（字符串）或 List（已解析）
  ///   - JS 字符串 "abc" → Dart 收到 '"abc"'（带引号）
  /// 这里逐层 jsonDecode，直到拿到非字符串的数组/对象，或裸字符串为止。
  /// 注意 SVG outerHTML / PNG dataURL 这类内容不以 [ { " 开头，不会被误解码。
  static dynamic _unwrap(Object? v) {
    dynamic cur = v;
    for (int i = 0; i < 3 && cur is String; i++) {
      final s = cur.trim();
      if (!(s.startsWith('[') || s.startsWith('{') || s.startsWith('"'))) {
        return cur; // 裸字符串（dataURL、HTML 等），保持原样
      }
      try {
        cur = jsonDecode(s);
      } catch (_) {
        return cur;
      }
    }
    return cur;
  }
}
