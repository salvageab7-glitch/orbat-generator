/// 本地机械化修复 —— 能本地修的错误绝不交给模型重写
///
/// 为什么需要：让模型"修一遍整棵树"风险极高。
/// 实测把 176 个节点的编制交给模型修复，它只返回 32 个节点——
/// 大 JSON 要么被截断，要么模型自己压缩了结构，数据大量丢失。
///
/// 而校验器报的红牌里，绝大多数是**机械性问题**：
///   - SIDC 不是 30 位（多写/少写 0）
///   - 名称里有「空格 + 左括号」（渲染器会卡死）
///   - 注释超过 24 个汉字（图上会溢出）
/// 这些用字符串规范化就能修，不需要任何语义判断。
library;

import 'orbat.dart';

class OrbatAutoFix {
  /// 对整棵树做机械修复，返回新树（不修改原对象）
  static OrbatNode apply(OrbatNode root) => _fix(root);

  static OrbatNode _fix(OrbatNode n) {
    return OrbatNode(
      uniqueDesignation: _fixName(n.uniqueDesignation),
      additionalInformation: _fixNote(n.additionalInformation),
      sidc: _fixSidc(n.sidc),
      children: n.children.map(_fix).toList(),
    );
  }

  /// SIDC：去非数字、按 30 位补齐或截断
  static String _fixSidc(String raw) {
    var s = raw.replaceAll(RegExp(r'\D'), '');
    if (s.isEmpty) s = '130310001500000000000000000000';

    if (s.length < 30) {
      // 少位：末尾补 0（保留位本来就是 0，补在尾部语义最安全）
      s = s.padRight(30, '0');
    } else if (s.length > 30) {
      // 多位：优先认为尾部多写了保留位的 0，从尾部截掉
      s = s.substring(0, 30);
    }

    // 版本位必须是 13
    if (!s.startsWith('13')) {
      s = '13${s.substring(2)}';
    }
    // 保留位（22-29）应为全 0
    s = '${s.substring(0, 22)}00000000';
    return s;
  }

  /// 名称：去掉「空格 + 左括号」里的空格（渲染器会卡死）
  static String _fixName(String name) {
    var s = name.trim();
    s = s.replaceAllMapped(RegExp(r'\s+\('), (_) => '(');
    s = s.replaceAllMapped(RegExp(r'\)\s+'), (_) => ')');
    return s;
  }

  /// 注释：汉字超过 24 个就截断
  static String _fixNote(String note) {
    final s = note.trim();
    if (_cjkCount(s) <= 24) return s;

    final buf = StringBuffer();
    var cjk = 0;
    for (final rune in s.runes) {
      if (rune > 0x2E80) {
        if (cjk >= 24) break;
        cjk++;
      }
      buf.writeCharCode(rune);
    }
    return buf.toString();
  }

  static int _cjkCount(String s) => s.runes.where((r) => r > 0x2E80).length;
}
