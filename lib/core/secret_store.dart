/// API Key 等敏感串的本地加密。
/// Windows 使用 DPAPI（CurrentUser）；Android 使用 Android Keystore AES-GCM。
/// 不支持安全存储的平台或系统加密失败时 fail closed，不写入可逆混淆密文。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import 'logger.dart';

class SecretStore {
  static const String _dpapiPrefix = 'dpapi:';
  static const String _androidPrefix = 'android-keystore:';
  static const String _xorPrefix = 'xor:';
  static const MethodChannel _androidChannel = MethodChannel('orbat/secret');

  /// _kUiForbidden（win32 包未导出该常量，直接写字面值）。
  static const int _kUiForbidden = 0x1;

  /// 旧版 XOR 固定密钥，仅供读取并迁移既有配置；绝不用于新写入。
  static const String _legacyKey = 'orbat-gen-v1';

  static bool get dpapiSupported => Platform.isWindows;

  /// 加密。若平台加密不可用，返回空串以阻止写入 API Key 明文/弱密文。
  static Future<String> seal(String plain) async {
    if (plain.isEmpty) return '';
    if (Platform.isWindows) {
      try {
        final out = _protect(utf8.encode(plain));
        if (out != null) return '$_dpapiPrefix${base64.encode(out)}';
      } catch (e) {
        AppLogger.instance.warn('secret', 'DPAPI 加密失败；已拒绝保存 API Key: $e');
      }
      return '';
    }
    if (Platform.isAndroid) {
      try {
        final payload = await _androidChannel.invokeMethod<String>(
          'seal',
          <String, Object>{'plain': plain},
        );
        if (payload != null && payload.isNotEmpty) {
          return '$_androidPrefix$payload';
        }
      } catch (e) {
        AppLogger.instance.warn(
          'secret',
          'Android Keystore 加密失败；已拒绝保存 API Key: $e',
        );
      }
      return '';
    }
    AppLogger.instance.warn('secret', '当前平台没有安全密钥存储；已拒绝持久化 API Key');
    return '';
  }

  /// 解密新格式并兼容旧 XOR 配置，以便升级后重新保存为系统密文。
  static Future<String> open(String stored) async {
    if (stored.isEmpty) return '';
    try {
      if (stored.startsWith(_dpapiPrefix)) {
        if (!Platform.isWindows) return '';
        final bytes = base64.decode(stored.substring(_dpapiPrefix.length));
        final plain = _unprotect(bytes);
        if (plain != null) return utf8.decode(plain);
        AppLogger.instance.warn(
          'secret',
          'DPAPI 解密失败（换机器/换账户/文件被改动），请重新填写 API Key',
        );
        return '';
      }
      if (stored.startsWith(_androidPrefix)) {
        if (!Platform.isAndroid) return '';
        final payload = stored.substring(_androidPrefix.length);
        return await _androidChannel.invokeMethod<String>(
              'open',
              <String, Object>{'payload': payload},
            ) ??
            '';
      }
      if (stored.startsWith(_xorPrefix)) {
        return utf8.decode(
          _xor(base64.decode(stored.substring(_xorPrefix.length))),
        );
      }
      // 历史格式：无前缀的 XOR base64。
      return utf8.decode(_xor(base64.decode(stored)));
    } catch (e) {
      AppLogger.instance.warn('secret', '配置里的密钥解不开，按空值处理: $e');
      return '';
    }
  }

  /// 旧 XOR 密文需在下次保存时迁移到 DPAPI / Android Keystore。
  static bool isLegacy(String stored) =>
      stored.isNotEmpty &&
      !stored.startsWith(_dpapiPrefix) &&
      !stored.startsWith(_androidPrefix) &&
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
        AppLogger.instance.warn(
          'secret',
          'CryptProtectData 失败，错误码 ${GetLastError()}',
        );
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
        AppLogger.instance.warn(
          'secret',
          'CryptUnprotectData 失败，错误码 ${GetLastError()}',
        );
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
    return List<int>.generate(
      bytes.length,
      (i) => bytes[i] ^ key[i % key.length],
    );
  }
}
