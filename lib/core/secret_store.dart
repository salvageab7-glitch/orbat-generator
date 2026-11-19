/// API Key 等敏感串的本地加密（Windows DPAPI）
///
/// 为什么换掉原来的 XOR：
///   旧实现是「固定字符串 XOR + base64」，密钥就写在开源代码里——
///   拿到 config.json 的人 5 行代码就能还原，等于明文。
///
/// 现在用 Windows 自带的 DPAPI（CryptProtectData，CurrentUser 作用域）：
///   · 同一台机器、同一个 Windows 账户才能解密；换机器/换账户解不开
///   · 不需要我们管理密钥（密钥由系统按用户派生）
///   · 纯 Dart FFI 实现，GUI 与 CLI（AOT）共用同一套逻辑
///
/// 存储格式（config.json 的 apiKey 字段）：
///   `dpapi:<base64>`  —— DPAPI 密文（正常情况）
///   `xor:<base64>`    —— 回退方案（非 Windows / DPAPI 不可用）
///   `<base64>`        —— 历史遗留的旧格式（无前缀），读取时按 XOR 解，下次保存自动转 DPAPI
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

  /// _kUiForbidden（win32 包未导出该常量，直接写字面值）
  static const int _kUiForbidden = 0x1;

  /// 旧版 XOR 用的固定密钥（只为读得动老配置，新写入不再用它）
  static const String _legacyKey = 'orbat-gen-v1';

  /// 本机是否支持 DPAPI（仅 Windows）
  static bool get dpapiSupported => Platform.isWindows;

  /// 加密。失败时退回 XOR，绝不因为加密失败而丢配置。
  static String seal(String plain) {
    if (plain.isEmpty) return '';
    if (dpapiSupported) {
      try {
        final out = _protect(utf8.encode(plain));
        if (out != null) return '$_dpapiPrefix${base64.encode(out)}';
      } catch (e) {
        AppLogger.instance.warn('secret', 'DPAPI 加密失败，退回混淆存储: $e');
      }
    }
    return '$_xorPrefix${base64.encode(_xor(utf8.encode(plain)))}';
  }

  /// 解密。兼容三种格式（见文件头）。
  static String open(String stored) {
    if (stored.isEmpty) return '';
    try {
      if (stored.startsWith(_dpapiPrefix)) {
        final bytes = base64.decode(stored.substring(_dpapiPrefix.length));
        final plain = _unprotect(bytes);
        if (plain != null) return utf8.decode(plain);
        AppLogger.instance.warn('secret',
            'DPAPI 解密失败（换机器/换账户/文件被改动），请重新填写 API Key');
        return '';
      }
      if (stored.startsWith(_xorPrefix)) {
        return utf8.decode(_xor(base64.decode(stored.substring(_xorPrefix.length))));
      }
      // 旧格式：无前缀的 XOR base64
      return utf8.decode(_xor(base64.decode(stored)));
    } catch (e) {
      AppLogger.instance.warn('secret', '配置里的密钥解不开，按空值处理: $e');
      return '';
    }
  }

  /// 判断一个存储值是不是当前推荐的格式（用于启动时迁移）
  static bool isLegacy(String stored) =>
      stored.isNotEmpty &&
      !stored.startsWith(_dpapiPrefix) &&
      !stored.startsWith(_xorPrefix);

  // ---------- DPAPI ----------

  static Uint8List? _protect(List<int> data) {
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    final inBuf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      if (data.isNotEmpty) inBuf.asTypedList(data.length).setAll(0, data);
      inBlob.ref.cbData = data.length;
      inBlob.ref.pbData = inBuf;

      final ok = CryptProtectData(inBlob, nullptr, nullptr, nullptr, nullptr,
          _kUiForbidden, outBlob);
      if (ok == 0) {
        AppLogger.instance.warn('secret', 'CryptProtectData 失败，错误码 ${GetLastError()}');
        return null;
      }
      final n = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(n));
    } finally {
      if (outBlob.ref.pbData != nullptr) {
        LocalFree(outBlob.ref.pbData.cast());
      }
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

      final ok = CryptUnprotectData(inBlob, nullptr, nullptr, nullptr, nullptr,
          _kUiForbidden, outBlob);
      if (ok == 0) {
        AppLogger.instance
            .warn('secret', 'CryptUnprotectData 失败，错误码 ${GetLastError()}');
        return null;
      }
      final n = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(n));
    } finally {
      if (outBlob.ref.pbData != nullptr) {
        LocalFree(outBlob.ref.pbData.cast());
      }
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  // ---------- 回退：XOR（与旧版算法完全一致，保证老配置读得动）----------

  static List<int> _xor(List<int> bytes) {
    final key = utf8.encode(_legacyKey);
    return List<int>.generate(bytes.length, (i) => bytes[i] ^ key[i % key.length]);
  }
}
