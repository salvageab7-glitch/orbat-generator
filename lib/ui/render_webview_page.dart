/// 安卓端出图页面（方案 A）—— 挂载内置 WebView 执行线上站点渲染
///
/// 职责：
///   - 创建 WebViewController（JS 全开、可访问跨域字体等站点资源）
///   - 全屏挂载 WebView（用户能看到站点加载过程，顶部有进度日志面板）
///   - 驱动 [WebViewRenderer] 跑完导入→渲染→导出流程
///   - 完成后把 [RenderResult] pop 回调用方
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../render/renderer.dart';
import '../render/webview_renderer.dart';
import '../i18n/l10n.dart';

class RenderWebViewPage extends StatefulWidget {
  /// 归一化后的完整树 JSON
  final String normalizedJson;

  /// 输出基名（不含扩展名）
  final String outputBase;

  /// PNG 倍率
  final int scale;

  /// PNG 白底
  final bool whiteBackground;

  const RenderWebViewPage({
    super.key,
    required this.normalizedJson,
    required this.outputBase,
    this.scale = 2,
    this.whiteBackground = true,
  });

  @override
  State<RenderWebViewPage> createState() => _RenderWebViewPageState();
}

class _RenderWebViewPageState extends State<RenderWebViewPage> {
  WebViewController? _controller;
  final List<String> _logLines = [];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final c = WebViewController.fromPlatformCreationParams(
      AndroidWebViewControllerCreationParams(),
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF15171C));
    (c.platform as AndroidWebViewController)
      ..setMediaPlaybackRequiresUserGesture(false)
      ..setOnShowFileSelector((_) async => const []); // 兜底：站点原生文件选择直接拒绝
    _controller = c;
    // 首帧后再开跑，保证 WebView 已挂到树上
    Future<void>.microtask(() => _run());
  }

  Future<void> _run() async {
    final c = _controller;
    if (c == null) return;
    final result = await WebViewRenderer.render(
      c,
      WebViewRenderJob(
        normalizedJson: widget.normalizedJson,
        outputBase: widget.outputBase,
        scale: widget.scale,
        whiteBackground: widget.whiteBackground,
      ),
      onLog: (line) {
        if (!mounted) return;
        setState(() {
          _logLines.add(line);
          if (_logLines.length > 200) _logLines.removeAt(0);
        });
      },
    );
    if (!mounted) return;
    setState(() => _done = true);
    // 成功时短暂展示结果后返回；失败时也返回（调用方负责提示）
    await Future<void>.delayed(
        Duration(milliseconds: result.ok ? 1200 : 400));
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(_done
            ? tr('出图完成')
            : tr('出图中 · 联网渲染（约 15-60 秒）')),
        automaticallyImplyLeading: !_done, // 渲染中不给后退，避免打断
      ),
      body: Stack(
        children: [
          // WebView 全屏挂着（页面可见，避免某些机型对不可见 WebView 节流）
          if (c != null) WebViewWidget(controller: c),
          // 顶部进度面板
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: Container(
                color: Colors.black.withValues(alpha: 0.55),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  itemCount: _logLines.length,
                  itemBuilder: (_, i) => Text(
                    _logLines[i],
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white, height: 1.4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
