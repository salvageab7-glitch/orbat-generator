/// OpenAI 兼容模型列表读取。
///
/// 通用服务：GET {base}/models → data[].id
/// OpenCode Go：额外读取 console metadata，过滤 chat 模型并标记 vision。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_endpoint.dart';

class ApiModelInfo {
  final String id;
  final String? name;
  final bool vision;
  final bool chat;

  const ApiModelInfo({
    required this.id,
    this.name,
    this.vision = false,
    this.chat = true,
  });

  String get displayName =>
      (name == null || name!.trim().isEmpty ? id : '$name ($id)') +
      (vision ? ' · vision' : '');
}

class ModelCatalogResult {
  final List<ApiModelInfo> models;
  final String? error;
  final String? warning;
  final bool usedMetadata;

  const ModelCatalogResult({
    this.models = const [],
    this.error,
    this.warning,
    this.usedMetadata = false,
  });

  bool get ok => error == null && models.isNotEmpty;
}

class ModelCatalogException implements Exception {
  final String message;
  const ModelCatalogException(this.message);
  @override
  String toString() => message;
}

/// 读取模型列表。失败时返回 `error`，不抛异常给 UI。
Future<ModelCatalogResult> fetchApiModels({
  required String apiBaseUrl,
  required String apiKey,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final base = normalizeApiBaseUrl(apiBaseUrl);
  final key = apiKey.trim();
  if (key.isEmpty) {
    return const ModelCatalogResult(error: '请先填写 API Key');
  }

  List<ApiModelInfo> generic;
  try {
    final json = await _getJson(modelsUrl(base), key, timeout);
    generic = parseGenericModels(json);
    if (generic.isEmpty) {
      return const ModelCatalogResult(error: '接口返回的模型列表为空');
    }
  } on ModelCatalogException catch (e) {
    return ModelCatalogResult(error: e.message);
  } catch (e) {
    return ModelCatalogResult(error: '读取模型列表失败：$e');
  }

  if (!isOpenCodeHost(base)) {
    return ModelCatalogResult(models: generic);
  }

  // OpenCode：metadata 能区分 chat / embedding / image，并标记 vision。
  try {
    final json = await _getJson(
      'https://opencode.ai/console/api/v1/models',
      key,
      timeout,
    );
    final metadata = parseOpenCodeModels(
      json,
      go: isOpenCodeGoBase(base),
    );
    if (metadata.isNotEmpty) {
      return ModelCatalogResult(
        models: metadata,
        usedMetadata: true,
      );
    }
  } on ModelCatalogException catch (e) {
    return ModelCatalogResult(
      models: generic,
      warning: '已读取通用模型列表；OpenCode 能力元数据不可用：${e.message}',
    );
  } catch (_) {}

  return ModelCatalogResult(
    models: generic,
    warning: '已读取通用模型列表；无法区分 chat/vision 能力。',
  );
}

Future<Map<String, dynamic>> _getJson(
  String url,
  String apiKey,
  Duration timeout,
) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer $apiKey');
    request.headers.set('Accept', 'application/json');
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ModelCatalogException('API Key 无效或无权限（401/403）');
    }
    if (response.statusCode == 404) {
      throw const ModelCatalogException('接口没有 /models（404），请检查 API 地址');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelCatalogException('读取模型列表失败：HTTP ${response.statusCode}');
    }
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const ModelCatalogException('模型列表响应不是 JSON 对象');
    }
    return decoded;
  } on TimeoutException {
    throw const ModelCatalogException('读取模型列表超时，请检查网络或 API 地址');
  } on SocketException {
    throw const ModelCatalogException('无法连接 API 地址，请检查网络/域名');
  } finally {
    client.close(force: true);
  }
}

List<ApiModelInfo> parseGenericModels(Map<String, dynamic> json) {
  final data = json['data'];
  if (data is! List) return const [];
  final out = <ApiModelInfo>[];
  final seen = <String>{};
  for (final item in data) {
    if (item is! Map) continue;
    final id = (item['id'] ?? '').toString().trim();
    if (id.isEmpty || !seen.add(id)) continue;
    out.add(ApiModelInfo(id: id));
  }
  return out;
}

List<ApiModelInfo> parseOpenCodeModels(
  Map<String, dynamic> json, {
  required bool go,
}) {
  final catalog = json[go ? 'opencode-go' : 'opencode'];
  if (catalog is! Map) return const [];
  final models = catalog['models'];
  if (models is! Map) return const [];

  final out = <ApiModelInfo>[];
  final seen = <String>{};
  for (final entry in models.entries) {
    final raw = entry.value;
    if (raw is! Map) continue;
    if ((raw['type'] ?? '').toString() != 'chat') continue;
    final id = (raw['id'] ?? entry.key).toString().trim();
    if (id.isEmpty || !seen.add(id)) continue;
    final modalities = raw['modalities'];
    final inputs = modalities is Map ? modalities['input'] : null;
    final vision = inputs is List &&
        inputs.any((m) => m.toString().toLowerCase().startsWith('image/'));
    out.add(ApiModelInfo(
      id: id,
      name: (raw['name'] ?? '').toString(),
      vision: vision,
    ));
  }
  return out;
}
