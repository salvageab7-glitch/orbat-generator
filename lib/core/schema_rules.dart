/// 字段级硬规则 —— 注释长度、名称写法、标注口径
///
/// 为什么单独成文件：提示词、本地校验器、机械修复、一致性审计、UI 提示
/// 五处必须用**同一套判定**，否则会出现「提示词说 12 字、校验器按 24 字放行」
/// 这种自相矛盾，模型与用户都无所适从。
///
/// 2026-11-18 用户新规（替代原 24 汉字）：
///   · 注释硬上限：3 个中文词语 ≈ **12 个汉字**；英文等拼音文字 **20 个字母**
///   · 注释内容只写驻地或职能短名；**不写指挥官姓名**
///   · 部队称号（如「近卫」「莫斯科」）并入名称/番号，不塞进注释
library;

/// 注释汉字上限（3 个中文词折算）
const int kNoteMaxCjk = 12;

/// 注释字母上限（拼音文字统一按字母计）
const int kNoteMaxLetters = 20;

/// 渲染器安全名称长度（仅渲染前适配用，导出 JSON 保持原文）
const int kRenderNameMax = 26;

/// 渲染器安全注释长度（渲染前适配用）
const int kRenderNoteMax = 40;

/// 是否为 CJK 汉字（不含标点：CJK 标点/全角符号不算字）
bool isCjkHan(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意
    (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
    (rune >= 0xF900 && rune <= 0xFAFF); // 兼容表意

/// 是否字母（拉丁 + 西里尔 + 希腊；数字与空格不计）
bool isAlphabetic(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) ||
    (rune >= 0x61 && rune <= 0x7A) ||
    (rune >= 0x0400 && rune <= 0x04FF) || // 西里尔
    (rune >= 0x0370 && rune <= 0x03FF); // 希腊

/// 注释用量统计
class NoteUsage {
  final int cjk; // 汉字数
  final int letters; // 字母数
  final bool ok;
  const NoteUsage(this.cjk, this.letters, this.ok);

  /// 给 UI/日志用的一句话说明
  String get label => ok
      ? '合规（$cjk 汉字 / $letters 字母）'
      : '超限（$cjk/$kNoteMaxCjk 汉字，$letters/$kNoteMaxLetters 字母）';
}

/// 统计注释长度并判定是否合规
NoteUsage measureNote(String note) {
  var cjk = 0;
  var letters = 0;
  for (final r in note.runes) {
    if (isCjkHan(r)) {
      cjk++;
    } else if (isAlphabetic(r)) {
      letters++;
    }
  }
  return NoteUsage(cjk, letters,
      cjk <= kNoteMaxCjk && letters <= kNoteMaxLetters);
}

/// 按硬上限裁剪注释：超汉字上限按字截断并补省略号；超字母上限按字母截断。
///
/// 单位驻地这类信息通常很短，正常不会触发；触发说明模型写了长句，
/// 与其让渲染器溢出，不如截断到合规并保留可读前缀。
String clampNote(String note) {
  final usage = measureNote(note);
  if (usage.ok) return note;

  final buf = StringBuffer();
  var cjk = 0;
  var letters = 0;
  var truncated = false;
  for (final r in note.runes) {
    final isHan = isCjkHan(r);
    final isLetter = isAlphabetic(r);
    if (isHan && cjk >= kNoteMaxCjk) {
      truncated = true;
      break;
    }
    if (isLetter && letters >= kNoteMaxLetters) {
      truncated = true;
      break;
    }
    if (isHan) cjk++;
    if (isLetter) letters++;
    buf.writeCharCode(r);
  }
  var out = buf.toString().trimRight();
  if (truncated && out.isNotEmpty) out = '$out…';
  return out;
}

/// 名称里是否含「空格 + 左括号」（渲染器会卡死）
final RegExp kNameSpaceParen = RegExp(r'\s+\(');

/// 名称里是否含 ×N 合并写法
final RegExp kNameTimesN = RegExp(r'[×xX]\s*\d+');

/// 注释里是否像指挥官姓名/职务（如「师长张某某」）
final RegExp kCommanderPattern = RegExp(r'(师长|旅长|团长|营长|连长|排长)[^\s·,，]{2,4}');

/// 注释里是否含自检说明（模型把质量备注写进数据字段）
///
/// 注意：「推断」不在黑名单里——提示词明确允许对推断单位标注「推断」，
/// 那是有效信息；要清掉的是「名称被裁切/符号不清/待确认」这类质量备注。
final RegExp kSelfCheckNotePattern =
    RegExp(r'名称被裁切|符号不清|看不清|疑似|待确认|无法确认|图上不清|残缺');
