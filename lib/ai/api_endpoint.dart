/// OpenAI 兼容 API 地址工具。
///
/// 统一处理：
///   · 末尾斜杠
///   · 完整 `/chat/completions` 或 `/models` 地址
///   · DeepSeek / OpenCode 主机识别
library;

const String kDefaultApiBaseUrl = 'https://api.deepseek.com';
const String kDefaultDeepSeekModel = 'deepseek-flash';

String normalizeApiBaseUrl(String raw) {
  var b = raw.trim();
  if (b.isEmpty) b = kDefaultApiBaseUrl;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  // 用户误填完整 chat/models 地址时，退回 base。
  if (b.endsWith('/chat/completions')) {
    b = b.substring(0, b.length - '/chat/completions'.length);
  } else if (b.endsWith('/models')) {
    b = b.substring(0, b.length - '/models'.length);
  }
  return b;
}

String chatCompletionsUrl(String baseUrl) {
  final b = normalizeApiBaseUrl(baseUrl);
  return '$b/chat/completions';
}

String modelsUrl(String baseUrl) {
  final b = normalizeApiBaseUrl(baseUrl);
  return '$b/models';
}

String _host(String baseUrl) =>
    (Uri.tryParse(normalizeApiBaseUrl(baseUrl))?.host ?? '').toLowerCase();

bool isDeepSeekHost(String baseUrl) => _host(baseUrl).contains('deepseek.com');

bool isOpenCodeHost(String baseUrl) => _host(baseUrl).endsWith('opencode.ai');

/// OpenCode Go 的 base 通常含 `/go/`（zen/go/v1 或 inference/go/openai/v1）。
bool isOpenCodeGoBase(String baseUrl) {
  if (!isOpenCodeHost(baseUrl)) return false;
  final path =
      (Uri.tryParse(normalizeApiBaseUrl(baseUrl))?.path ?? '').toLowerCase();
  return path.contains('/go/') || path.endsWith('/go');
}
