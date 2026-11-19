/// DeepSeek API 客户端（纯 dart:io，零依赖）
/// 端点：POST https://api.deepseek.com/chat/completions
/// 能力：deepseek-flash 视觉输入 + JSON Output + 空 content 重试兜底
///
/// ⚠️ 关键坑（2026-11 实测）：deepseek-flash 默认开启思考模式（effort=high），
/// 返回时 `content` 为空、全部内容落在 `reasoning_content`，且很容易把
/// max_tokens 耗光导致 finish_reason=length。必须显式传
/// `thinking: {type: "disabled"}` 才能拿到干净的 JSON 输出。
/// `reasoning_effort: low` **无效**（仍会思考并被截断）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/orbat.dart';
import '../core/logger.dart';
import '../core/usage_store.dart';

class DeepSeekConfig {
  final String apiKey;
  final String model; // deepseek-flash（支持图像）；deepseek-v4-pro 不支持图像
  final String baseUrl;
  final int maxTokens;
  final int maxRetries;
  final Duration timeout;

  /// 是否关闭思考模式。默认关闭——编制抽取是结构化任务，
  /// 思考过程只会占用输出预算并污染 JSON。
  final bool disableThinking;

  DeepSeekConfig({
    required this.apiKey,
    this.model = 'deepseek-flash',
    this.baseUrl = 'https://api.deepseek.com',
    // 单块大树（100+ 节点）的 JSON 约需 1-2 万 token。
    // 之前设 64000 反而害事：模型看不清图时在「观察」段狂写列清单，
    // 把 64000 全耗尽（实测输出 196 列「看不清」、耗时 248 秒、还没到 <json> 就被截断）。
    // 收到 24000：足够正常大块，又不会让失控输出拖那么久。
    this.maxTokens = 24000,
    // 重试 2 次即可（3 次 × 长输出 = 卡住几分钟）
    this.maxRetries = 2,
    // 单次调用总超时 60 秒。实测正常块 2-35 秒完成，超大密集块会跑 98 秒+
    // 且最终仍被截断——那种情况早点超时跳过，比死等更有价值。
    // 注意 timeout 覆盖「建连 + 读完响应体」整体（见 _runWithRetry）。
    this.timeout = const Duration(seconds: 60),
    this.disableThinking = true,
  });
}

class GenerateResult {
  final OrbatNode? tree;
  final String rawJson;
  final int attempts;
  final String? error;

  GenerateResult({
    this.tree,
    required this.rawJson,
    required this.attempts,
    this.error,
  });

  bool get ok => tree != null;
}

/// 提取 AI 返回内容中可能夹杂的 markdown 代码块，拿出纯 JSON
String extractJson(String raw) {
  var s = raw.trim();
  // 去掉 ```json ... ``` 包裹
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
  final m = fence.firstMatch(s);
  if (m != null) s = m.group(1)!.trim();
  // 退而求其次：截取第一个 { 到最后一个 }
  if (!s.startsWith('{')) {
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start >= 0 && end > start) s = s.substring(start, end + 1);
  }
  return s;
}

class DeepSeekClient {
  final DeepSeekConfig config;
  final String systemPrompt;
  final HttpClient _http = HttpClient();

  /// 最近一次 API 对话的原始记录（静态，跨 client 实例保留）。
  /// 供 UI「查看 API 对话」面板展示：完整 prompt、模型三段式输出、token/耗时。
  static Map<String, dynamic>? _lastConversation;
  static Map<String, dynamic>? get lastConversation =>
      Map<String, dynamic>.from(_lastConversation ?? {});

  DeepSeekClient({required this.config, required this.systemPrompt});

  /// 从图片（base64）+ 可选文字生成 ORBAT 树
  Future<GenerateResult> generateFromImage({
    required List<int> imageBytes,
    String mimeType = 'image/png',
    String? extraText,
    bool jsonMode = true,
    void Function(String phase)? onProgress,
  }) async {
    final b64 = base64.encode(imageBytes);
    final userContent = <Map<String, dynamic>>[
      {
        'type': 'image_url',
        'image_url': {'url': 'data:$mimeType;base64,$b64'},
      },
      {'type': 'text', 'text': extraText ?? '请根据这张编制图图片输出编制 JSON。逐框清点，不要遗漏。'},
    ];
    return _runWithRetry(userContent, jsonMode: jsonMode, onProgress: onProgress);
  }

  /// 从图片获取**纯文本**（不解析 JSON）
  ///
  /// 用于"只让模型读名字和层级"的场景：实测要求模型同时产出 30 位 SIDC 会
  /// 明显拉低读图精度，所以把读图与构造码拆开。
  Future<String?> generateTextFromImage({
    required List<int> imageBytes,
    String mimeType = 'image/png',
    required String prompt,
    void Function(String phase)? onProgress,
  }) async {
    final b64 = base64.encode(imageBytes);
    final r = await _runWithRetry([
      {
        'type': 'image_url',
        'image_url': {'url': 'data:$mimeType;base64,$b64'},
      },
      {'type': 'text', 'text': prompt},
    ], jsonMode: false, onProgress: onProgress);

    if (r.error != null && r.rawJson.trim().isEmpty) return null;
    return r.rawJson.trim().isEmpty ? null : r.rawJson;
  }

  /// 仅从文字生成
  Future<GenerateResult> generateFromText(
    String text, {
    void Function(String phase)? onProgress,
  }) async {
    return _runWithRetry([
      {'type': 'text', 'text': text}
    ], onProgress: onProgress);
  }

  /// 记录一次失败的调用（状态码 / 响应体片段 / 耗时 / 第几次尝试）。
  ///
  /// 用户反馈"识别没反应"时，日志里的这一行通常就是结论：
  /// Key 无效(401)、余额不足(402)、限流(429)、服务 5xx、还是本机网络超时。
  /// 之前这些信息只存在内存里的 lastError，关窗即失，排查全靠猜。
  void _logFailure({
    required int attempt,
    required String stage,
    int? status,
    String? body,
    Object? error,
    int? elapsedMs,
  }) {
    final head = (body ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = head.length > 500 ? '${head.substring(0, 500)}…' : head;
    final errText = error?.toString().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    AppLogger.instance.warn(
      'ai-error',
      'attempt=$attempt/${config.maxRetries} stage=$stage'
      '${status != null ? " status=$status" : ""}'
      '${elapsedMs != null ? " ms=$elapsedMs" : ""}'
      '${errText.isNotEmpty ? " err=${errText.length > 200 ? "${errText.substring(0, 200)}…" : errText}" : ""}'
      '${snippet.isNotEmpty ? " body=$snippet" : ""}',
    );
  }

  /// 把 HTTP 状态翻译成可执行的提示（用户看得懂、知道该去干什么）
  String _describeHttp(int status, String body) {
    switch (status) {
      case 400:
        return '请求格式错误（400）：$body';
      case 401:
        return 'API Key 无效或无权限（401）。请在设置里重新填写 DeepSeek Key';
      case 402:
        return '账户余额不足（402）。请到 platform.deepseek.com 充值';
      case 403:
        return '请求被拒绝（403）。请检查 Key 的权限或所在网络是否被限制';
      case 429:
        return '请求过于频繁（429）。稍等几十秒再试，或减少批量任务数';
      default:
        if (status >= 500) {
          return 'DeepSeek 服务端异常（$status），稍后重试即可';
        }
        return 'HTTP $status: $body';
    }
  }

  Future<GenerateResult> _runWithRetry(
    List<Map<String, dynamic>> userContent, {
    bool jsonMode = true,
    void Function(String phase)? onProgress,
  }) async {
    String lastRaw = '';
    String? lastError;

    for (var attempt = 1; attempt <= config.maxRetries; attempt++) {
      onProgress?.call('第 $attempt 次请求 DeepSeek…');
      try {
        final body = <String, dynamic>{
          'model': config.model,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userContent},
          ],
          if (jsonMode) 'response_format': {'type': 'json_object'},
          'max_tokens': config.maxTokens,
          'temperature': 0.1,
          'stream': false,
          if (config.disableThinking) 'thinking': {'type': 'disabled'},
        };

        final request = await _http.postUrl(Uri.parse('${config.baseUrl}/chat/completions'));
        request.headers.set('Content-Type', 'application/json; charset=utf-8');
        request.headers.set('Authorization', 'Bearer ${config.apiKey}');
        // 必须用 utf8 编码字节流：HttpClientRequest.write(String) 默认按 Latin1 编码，
        // 遇到中文会抛 "Contains invalid characters"（system prompt 全是中文，必然踩到）。
        final t0 = DateTime.now();
        final payload = utf8.encode(json.encode(body));
        request.headers.contentLength = payload.length;
        request.add(payload);
        // 关键：把「建连 + 读完响应体」整体包进超时。
        // 只给 request.close() 加 timeout 不够——那只覆盖首字节，
        // 模型慢速吐 64000 token 时 join() 会一直等（实测 248 秒没被 180 秒超时拦住）。
        final resp = await () async {
          final response = await request.close().timeout(config.timeout);
          final body = await utf8.decoder.bind(response).join();
          return (status: response.statusCode, body: body);
        }().timeout(config.timeout, onTimeout: () {
          request.abort();
          throw TimeoutException('AI 响应超时（${config.timeout.inSeconds}秒）');
        });
        final respBody = resp.body;

        if (resp.status != 200) {
          lastError = _describeHttp(resp.status, respBody);
          _logFailure(
            attempt: attempt,
            stage: 'http',
            status: resp.status,
            body: respBody,
            elapsedMs: DateTime.now().difference(t0).inMilliseconds,
          );
          onProgress?.call('请求失败：$lastError');
          // 401/402/403 属于"重试也没用"的错误，立刻停止，别让用户白等两轮
          if (resp.status == 401 || resp.status == 402 || resp.status == 403) {
            break;
          }
          continue;
        }

        final decoded = json.decode(respBody) as Map<String, dynamic>;
        final choices = decoded['choices'] as List?;
        if (choices == null || choices.isEmpty) {
          lastError = '响应无 choices';
          continue;
        }
        final message = choices[0]['message'] as Map? ?? const {};
        final content = (message['content'] ?? '').toString();
        final reasoning = (message['reasoning_content'] ?? '').toString();
        final finishReason = (choices[0]['finish_reason'] ?? '').toString();
        final usage = decoded['usage'] as Map? ?? const {};
        final callMs = DateTime.now().difference(t0).inMilliseconds;
        final inTok0 = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
        final outTok0 = (usage['completion_tokens'] as num?)?.toInt() ?? 0;

        // 保存原始响应供「查看 API 对话」面板展示。
        // userContent 里的 base64 图片不落展示文本（太大），只标注字节数。
        _lastConversation = {
          'time': DateTime.now().toIso8601String(),
          'model': config.model,
          'system': systemPrompt,
          'user': userContent
              .map((m) => m['type'] == 'text'
                  ? m['text'].toString()
                  : '[图片 ${m['image_url']?['url']?.toString().length ?? 0} 字符 base64]')
              .join('\n'),
          'content': content,
          'reasoning': reasoning,
          'finish': finishReason,
          'inTok': inTok0,
          'outTok': outTok0,
          'ms': callMs,
        };

        if (content.trim().isEmpty) {
          if (finishReason == 'length') {
            lastError = '输出被 max_tokens 截断（finish_reason=length）'
                '${reasoning.isNotEmpty ? "，且全部消耗在思考过程" : ""}。'
                '请确认已关闭思考模式，或调大 max_tokens。';
            lastRaw = reasoning.isNotEmpty ? reasoning : content;
            break;
          } else if (reasoning.isNotEmpty) {
            lastError = 'content 为空，内容只出现在 reasoning_content（思考模式未关闭）';
          } else {
            lastError = '返回 content 为空（JSON Output 兜底触发）';
          }
          lastRaw = content.isNotEmpty ? content : reasoning;
          _logFailure(
            attempt: attempt,
            stage: finishReason == 'length' ? 'truncated-empty' : 'empty-content',
            status: resp.status,
            body: reasoning.isNotEmpty ? reasoning : content,
            elapsedMs: callMs,
          );
          onProgress?.call('$lastError，重试…');
          continue;
        }
        lastRaw = content;

        // 记录这次调用的用量与结果，排查提示词问题全靠这里
        final lg = AppLogger.instance;
        lg.info('ai', 'model=${config.model} | '
            'in=$inTok0 out=$outTok0 | '
            '${callMs}ms | finish=${finishReason.isEmpty ? '-' : finishReason} | '
            '请求体=${(payload.length / 1024).toStringAsFixed(0)}KB 响应=${content.length}字');

        // 记一笔用量，供「API 用量」面板统计
        UsageStore.record(
          scene: jsonMode ? '生成/修复' : '识图',
          promptTokens: inTok0,
          completionTokens: outTok0,
          ms: callMs,
          model: config.model,
        );
        lg.debug('ai', '响应正文:\n$content');

        // 截断的输出一定不完整。不再重试——重试只会再花同样长的时间碰运气
        // （实测失控输出重试 3 次 = 卡住 12 分钟）。直接返回清晰错误，
        // 让上层提示用户：图太密集，程序会自动切片；或补充结构提示。
        if (finishReason == 'length') {
          lastError = 'AI 输出达到上限（${config.maxTokens} token）被截断，'
              '未生成完整 JSON。这张图单位过多/文字过密，'
              '请尝试：① 用裁剪工具把图分成几张分别识别；② 在补充说明里写结构骨架。';
          onProgress?.call('输出过长被截断，已停止重试');
          _logFailure(
            attempt: attempt,
            stage: 'truncated',
            status: resp.status,
            body: 'inTok=$inTok0 outTok=$outTok0 finish=$finishReason',
            elapsedMs: callMs,
          );
          lastRaw = content;
          break;
        }

        // 纯文本模式：不解析，直接交回内容
        if (!jsonMode) {
          return GenerateResult(tree: null, rawJson: content, attempts: attempt);
        }

        // 尝试解析
        final clean = extractJson(content);
        final parsed = json.decode(clean) as Map<String, dynamic>;
        onProgress?.call('解析成功，构建编制树…');
        final tree = OrbatNode.fromJson(parsed);
        return GenerateResult(tree: tree, rawJson: clean, attempts: attempt);
      } catch (e) {
        lastError = e.toString();
        _logFailure(attempt: attempt, stage: 'exception', error: e);
        onProgress?.call('解析异常：$lastError');
      }
    }

    return GenerateResult(
      tree: null,
      rawJson: lastRaw,
      attempts: config.maxRetries,
      error: lastError ?? '未知错误',
    );
  }

  void close() => _http.close();
}
