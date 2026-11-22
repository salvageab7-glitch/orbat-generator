/// Windows DPAPI 与历史密钥格式测试。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbat_core/core/secret_store.dart';

/// 复刻旧版算法，用于造历史格式样本。
List<int> legacyXor(List<int> bytes) {
  const key = 'orbat-gen-v1';
  final k = utf8.encode(key);
  return List<int>.generate(bytes.length, (i) => bytes[i] ^ k[i % k.length]);
}

void main() {
  const sample = 'sk-1234567890abcdefghijklmn';
  final windowsOnly = !Platform.isWindows;

  test('Windows DPAPI 密文可往返，且不含明文', () async {
    final sealed = await SecretStore.seal(sample);
    expect(sealed.startsWith('dpapi:'), isTrue);
    expect(sealed.contains(sample), isFalse);
    expect(await SecretStore.open(sealed), sample);
  }, skip: windowsOnly);

  test('空值不进加密流程', () async {
    expect(await SecretStore.seal(''), '');
    expect(await SecretStore.open(''), '');
  });

  test('新格式和未知前缀不会被误判为旧密文', () {
    expect(SecretStore.isLegacy('dpapi:opaque'), isFalse);
    expect(SecretStore.isLegacy('android-keystore:opaque'), isFalse);
    expect(SecretStore.isLegacy('unknown:opaque'), isFalse);
  });

  test('旧版无前缀 XOR 密钥仍可读并标记迁移', () async {
    final legacy = base64.encode(legacyXor(utf8.encode(sample)));
    expect(SecretStore.isLegacy(legacy), isTrue);
    expect(await SecretStore.open(legacy), sample);
  });

  test('带 xor: 前缀的旧密文仅可迁移读取', () async {
    final fallback = 'xor:${base64.encode(legacyXor(utf8.encode(sample)))}';
    expect(SecretStore.isLegacy(fallback), isTrue);
    expect(await SecretStore.open(fallback), sample);
  });

  test('篡改 DPAPI 密文时返回空字符串', () async {
    final sealed = await SecretStore.seal(sample);
    final bytes = base64.decode(sealed.substring('dpapi:'.length));
    bytes[bytes.length ~/ 2] ^= 0xFF;
    expect(await SecretStore.open('dpapi:${base64.encode(bytes)}'), '');
  }, skip: windowsOnly);

  test('DPAPI 每次加密结果都不同', () async {
    final a = await SecretStore.seal(sample);
    final b = await SecretStore.seal(sample);
    expect(a == b, isFalse);
    expect(await SecretStore.open(a), sample);
    expect(await SecretStore.open(b), sample);
  }, skip: windowsOnly);
}
