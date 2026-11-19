/// 本地机械化修复 —— 能本地修的错误绝不交给模型重写
///
/// 为什么需要：让模型"修一遍整棵树"风险极高。
/// 实测把 176 个节点的编制交给模型修复，它只返回 32 个节点——
/// 大 JSON 要么被截断，要么模型自己压缩了结构，数据大量丢失。
///
/// 而校验器报的红牌里，绝大多数是**机械性问题**：
///   - SIDC 不是 30 位（多写/少写 0）
///   - 名称里有「空格 + 左括号」（渲染器会卡死）
///   - 注释超过 12 个汉字 / 20 个字母（图上会溢出）
/// 这些用字符串规范化就能修，不需要任何语义判断。
library;

import 'orbat.dart';
import 'schema_rules.dart';

class OrbatAutoFix {
  /// 对整棵树做机械修复，返回新树（不修改原对象）
  static OrbatNode apply(OrbatNode root) => _fix(root);

  /// 自检说明黑名单——模型把「看不清」类说明写进了数据字段，
  /// 渲染出来就是「支援单位，符号不清」这种怪注释，必须清掉。
  /// 正则定义统一放在 schema_rules.dart，校验器与这里共用一套。
  static final RegExp _selfCheckNote = kSelfCheckNotePattern;

  /// 残缺占位标记，如「Sy[?]」「17th[?]」
  static final RegExp _truncatedMark = RegExp(r'\[\?\]$');

  static OrbatNode _fix(OrbatNode n) {
    final fixedChildren = n.children.map(_fix).toList();
    final merged = _mergeSiblings(fixedChildren);
    return OrbatNode(
      uniqueDesignation: _fixName(n.uniqueDesignation),
      additionalInformation: _fixNote(n.additionalInformation),
      sidc: _fixSidc(n.sidc),
      children: merged,
    );
  }

  /// 同一父节点下的兄弟去重合并（0.3.1 新增）。
  ///
  /// 分块识图时，跨块边界的同一单位常被两块各自识别：
  /// 一份名称残缺（「Sy[?]」、注释「M[?]」），一份完整。
  /// 旧逻辑只在挂载阶段按**同名**合并，残缺名与全名不同就漏网，
  /// 导致产图里同一个旅出现两份、注释一半是占位符。
  static List<OrbatNode> _mergeSiblings(List<OrbatNode> nodes) {
    final out = <OrbatNode>[];
    for (final node in nodes) {
      final name = node.uniqueDesignation;
      final truncated = _truncatedMark.hasMatch(name);
      final clean = name.replaceAll(_truncatedMark, '').trim();

      int targetIdx = -1;
      for (var i = 0; i < out.length; i++) {
        final on = out[i].uniqueDesignation;
        final onTruncated = _truncatedMark.hasMatch(on);
        final onClean = on.replaceAll(_truncatedMark, '').trim();
        // ① 完全同名：直接合并
        if (on == name) {
          targetIdx = i;
          break;
        }
        // ② 当前残缺、已有全名以残缺名开头（Sy[?] → Sydney University Regiment）
        if (truncated && clean.length >= 2 && on.startsWith(clean)) {
          targetIdx = i;
          break;
        }
        // ③ 已有残缺、当前全名以其开头（残缺先入列的反向场景）
        if (onTruncated && onClean.length >= 2 && name.startsWith(onClean)) {
          targetIdx = i;
          break;
        }
      }

      if (targetIdx < 0) {
        out.add(node);
        continue;
      }

      // 字段级补全：目标缺什么就用来源补什么，绝不覆盖已有完整值。
      // 名称：残缺方让位给完整方。OrbatNode 字段全 final，合并 = 构建新节点。
      final t = out[targetIdx];
      final tTruncated = _truncatedMark.hasMatch(t.uniqueDesignation);
      final mergedName =
          tTruncated && !truncated ? name : t.uniqueDesignation;
      final noteSrc = tTruncated && !truncated ? node : t;
      var note = noteSrc.additionalInformation;
      if (note.trim().isEmpty ||
          note.contains('[?]') ||
          _selfCheckNote.hasMatch(note)) {
        final other =
            identical(noteSrc, node) ? t : node;
        if (!other.additionalInformation.contains('[?]') &&
            !_selfCheckNote.hasMatch(other.additionalInformation)) {
          note = other.additionalInformation;
        }
      }
      var sidc = t.sidc;
      if (_isPlaceholderSidc(sidc) && !_isPlaceholderSidc(node.sidc)) {
        sidc = node.sidc;
      }
      out[targetIdx] = OrbatNode(
        uniqueDesignation: mergedName,
        additionalInformation: _fixNote(note),
        sidc: sidc,
        children: [...t.children, ...node.children],
      );
    }
    return out;
  }

  static bool _isPlaceholderSidc(String s) {
    final body = s.length > 15 ? s.substring(10, 16) : '';
    return body.isEmpty || body == '000000';
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

  /// 注释：自检说明清空；含 [?] 残缺标记清空（半截注释不如没有）；
  /// 超长按硬上限裁剪（12 汉字 / 20 字母，见 schema_rules.dart）
  static String _fixNote(String note) {
    var s = note.trim();
    if (_selfCheckNote.hasMatch(s) || s.contains('[?]')) return '';
    if (kCommanderPattern.hasMatch(s)) {
      // 「师长张某某」这类整句删掉；只删命中片段会留下残句，不如置空
      return '';
    }
    return clampNote(s);
  }
}
