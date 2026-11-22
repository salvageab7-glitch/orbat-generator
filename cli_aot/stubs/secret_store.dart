/// CLI/AOT 专用 SecretStore：只保留 Windows DPAPI，不依赖 Flutter。
///
/// `app/lib/core/secret_store.dart` 为了 Android Keystore 引入了
/// Flutter 的 services 库，而 CLI 是纯 Dart AOT，不能带入 Flutter。
/// 因此构建脚本在同步 `lib/core/` 后，用本文件覆盖 CLI 侧的副本。
/// 公共签名与 GUI 版保持一致：`Future<String> seal` / `Future<String> open` /
/// `bool isLegacy`，这样 `settings_store.dart` 不需要分支。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'logger.dart';

class SecretStore {
  static const String _dpapiPrefix = 'dpapi:';
  static const String _xorPrefix = 'xor:';
  static const int _kUiForbidden = 0x1;
  static const String _legacyKey = 'orbat-gen-v1';

  static bool get dpapiSupported => Platform.isWindows;

  /// 加密。CLI 不持久化 API Key 到 Android；失败时拒绝写入，绝不降级成弱密文。
  static Future<String> seal(String plain) async {
    if (plain.isEmpty) return '';
    if (!Platform.isWindows) {
      AppLogger.instance.warn('secret', 'CLI 仅支持 Windows DPAPI；已拒绝保存 API Key');
      return '';
    }
    try {
      final out = _protect(utf8.encode(plain));
      if (out != null) return '$_dpapiPrefix${base64.encode(out)}';
    } catch (e) {
      AppLogger.instance.warn('secret', 'DPAPI 加密失败；已拒绝保存 API Key: $e');
    }
    return '';
  }

  /// 解密新格式，并兼容旧 XOR 配置。
  static Future<String> open(String stored) async {
    if (stored.isEmpty) return '';
    try {
      if (stored.startsWith(_dpapiPrefix)) {
        if (!Platform.isWindows) return '';
        final bytes = base64.decode(stored.substring(_dpapiPrefix.length));
        final plain = _unprotect(bytes);
        if (plain != null) return utf8.decode(plain);
        AppLogger.instance.warn('secret', 'DPAPI 解密失败，请重新填写 API Key');
        return '';
      }
      if (stored.startsWith(_xorPrefix)) {
        return utf8.decode(_xor(base64.decode(stored.substring(_xorPrefix.length))));
      }
      return utf8.decode(_xor(base64.decode(stored)));
    } catch (e) {
      AppLogger.instance.warn('secret', '配置里的密钥解不开，按空值处理: $e');
      return '';
    }
  }

  static bool isLegacy(String stored) =>
      stored.isNotEmpty &&
      !stored.startsWith(_dpapiPrefix) &&
      (stored.startsWith(_xorPrefix) || !stored.contains(':'));

  static Uint8List? _protect(List<int> data) {
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    final inBuf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      if (data.isNotEmpty) inBuf.asTypedList(data.length).setAll(0, data);
      inBlob.ref.cbData = data.length;
      inBlob.ref.pbData = inBuf;

      final ok = CryptProtectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _kUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        AppLogger.instance.warn('secret', 'CryptProtectData 失败，错误码 ${GetLastError()}');
        return null;
      }
      final n = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(n));
    } finally {
      if (outBlob.ref.pbData != nullptr) LocalFree(outBlob.ref.pbData.cast());
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  static Uint8List? _unprotect(List<int> data) {
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    final inBuf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      if (data.isNotEmpty) inBuf.asTypedList(data.length).setAll(0, data);
      inBlob.ref.cbData = data.length;
      inBlob.ref.pbData = inBuf;

      final ok = CryptUnprotectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _kUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        AppLogger.instance.warn('secret', 'CryptUnprotectData 失败，错误码 ${GetLastError()}');
        return null;
      }
      final n = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(n));
    } finally {
      if (outBlob.ref.pbData != nullptr) LocalFree(outBlob.ref.pbData.cast());
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  static List<int> _xor(List<int> bytes) {
    final key = utf8.encode(_legacyKey);
    return List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
  }
}
