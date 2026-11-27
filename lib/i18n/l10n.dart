/// 界面语言（中 / 英）
///
/// 做法：以**中文原文为 key**的字典 + `tr()` 包装。
/// 为什么不用 key-value 常量表：现有代码里文案是散落的字面量，
/// 用中文原文当 key 可以做到「不改结构、只包一层」，且漏译时自动回退中文，
/// 不会出现空白或 key 裸露。
///
/// 约定：
///   · 日志（AppLogger / _appendLog）保持中文 —— 它是给排查问题用的，
///     混入英文反而让技术支持看不懂；render_orbat.js 的输出同理。
///   · 带插值的文案用 `tf('模板', {...})`，模板里用 `{name}` 占位。
library;

import 'dart:io';

enum AppLang { zh, en }

/// 界面语言状态（**纯 Dart**，不依赖 Flutter）
///
/// 为什么不放在 UI 层：`core/self_check.dart` 要在 CLI（AOT，无 Flutter）里编译，
/// 它也要用 tr()。这里只保留静态状态，界面重建交给 `l10n_ui.dart` 的通知器。
class L10n {
  static AppLang current = AppLang.zh;

  static bool get isEn => current == AppLang.en;

  /// 用配置里的语言码（'zh' / 'en' / ''=跟随系统）
  static void apply(String code) {
    if (code == 'en') {
      current = AppLang.en;
    } else if (code == 'zh') {
      current = AppLang.zh;
    } else {
      current = systemLang();
    }
  }

  /// 系统语言 → 界面语言。
  ///
  /// 探测顺序：
  ///   1. `Platform.localeName`（Windows 上取自 GetUserDefaultLocaleName，如 zh-CN / en-US）
  ///   2. LANG / LC_ALL 环境变量（Linux/macOS，以及被裁剪过的 Windows 环境）
  /// 规则按产品要求：中文系统 → 中文；**其他任何语言（英/日/俄…）→ 英文**；
  /// 完全探测不到时才退回中文（产品以中文为先）。
  static AppLang systemLang() {
    final byLocale = langForLocale(Platform.localeName);
    if (byLocale != null) return byLocale;

    final env = '${Platform.environment['LANG'] ?? ''}'
            '${Platform.environment['LC_ALL'] ?? ''}'
        .toLowerCase();
    final byEnv = langForLocale(env);
    if (byEnv != null) return byEnv;
    return AppLang.zh;
  }

  /// 纯函数：locale 字符串 → 语言；无法判断时返回 null（方便单测）。
  static AppLang? langForLocale(String localeName) {
    final s = localeName.trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s.startsWith('zh') || s.contains('chinese')) return AppLang.zh;
    // 明确是某种语言时一律英文（含 en / ja / ru / de …）
    if (RegExp(r'^[a-z]{2,3}([-_][a-z0-9]+)*$').hasMatch(s)) return AppLang.en;
    return null;
  }

  /// 系统语言的展示名（给首启对话框说明用）
  static String get systemLanguageLabel =>
      Platform.localeName.isEmpty ? '—' : Platform.localeName;

  static void setExplicit(AppLang value) => current = value;

  /// 翻译一条静态文案；没有对应词条时原样返回中文
  static String t(String zh) {
    if (!isEn) return zh;
    return _en[zh] ?? zh;
  }

  /// 翻译带占位符的模板：`tf('已导出到 {p}', {'p': path})`
  static String tf(String zh, Map<String, Object?> args) {
    var out = isEn ? (_en[zh] ?? zh) : zh;
    args.forEach((k, v) {
      out = out.replaceAll('{$k}', '${v ?? ''}');
    });
    return out;
  }
}

/// 便捷函数：界面代码里直接 `tr('出图')`
String tr(String zh) => L10n.t(zh);

/// 带占位符版本
String tf(String zh, Map<String, Object?> args) => L10n.tf(zh, args);

/// 词表：中文原文 → English
const Map<String, String> _en = {
  // ---------- 通用 ----------
  '取消': 'Cancel',
  '保存': 'Save',
  '关闭': 'Close',
  '确定': 'OK',
  '知道了': 'Got it',
  '我知道了': 'Got it',
  '清空': 'Clear',
  '重置（清空当前内容，回到初始状态）': 'Reset (clear everything)',
  '继续重置': 'Reset anyway',
  '对比': 'Compare',
  '跳过': 'Skip',
  '空': 'Empty',
  '（空）': '(empty)',
  '(无名)': '(unnamed)',
  '根': 'Root',
  '今日': 'Today',
  '本月': 'This month',
  '准备': 'Preparing',
  '就绪': 'Ready',
  '完成': 'Done',
  '失败': 'Failed',
  '异常': 'Error',
  '等待': 'Waiting',
  '处理中…': 'Working…',
  '(空)': '(empty)',

  // ---------- 窗口 / 顶栏 ----------
  '编制图生成器': 'ORBAT Generator',
  '编制图生成器已在运行': 'ORBAT Generator is already running',
  '请切换到已打开的窗口。此窗口即将关闭。':
      'Please switch to the existing window. This one will close.',
  '切换主题': 'Toggle theme',
  '设置': 'Settings',
  '指挥层级 commandLevels': 'Command levels (commandLevels)',
  '默认 3（推荐，排布更紧凑）；2 仅用于特殊宽树，可能反而更宽。会覆盖 JSON 根节点的设置。':
      '3 is recommended (more compact); use 2 only for special wide trees. It overrides the JSON root setting.',
  '3 · 默认（推荐）': '3 · Default (recommended)',
  '2 · 特殊宽树': '2 · Special wide tree',
  'API Key（OpenAI / DeepSeek）': 'API Key (OpenAI / DeepSeek)',
  'API 地址（OpenAI 兼容）': 'API base URL (OpenAI-compatible)',
  '填到 /v1 为止；也接受完整 /chat/completions。DeepSeek 留默认即可。':
      'Enter up to /v1; a full /chat/completions URL also works. Keep the default for DeepSeek.',
  '需与 API 地址匹配；可手填自定义模型 id':
      'Must match the API base URL; a custom model id can be typed.',
  '软件版本': 'Version',
  'AI 接口连通': 'AI API reachable',
  '服务类型': 'Service type',
  'DeepSeek 使用官方预设；OpenAI 兼容可填任意 /v1 地址（含 OpenCode Go）。':
      'DeepSeek uses presets; OpenAI-compatible accepts any /v1 endpoint (including OpenCode Go).',
  'OpenAI 兼容 / OpenCode Go': 'OpenAI-compatible / OpenCode Go',
  'API 地址（DeepSeek）': 'API base URL (DeepSeek)',
  '读取模型列表': 'Fetch model list',
  '读取中…': 'Fetching…',
  '可用模型': 'Available models',
  '来自 API 的 /models；标注 vision 的模型支持图片输入':
      'From the API /models; models marked vision support image input.',
  '请先填写 API 地址和 API Key': 'Enter the API base URL and API key first',
  '请先读取模型列表或手填模型 id': 'Fetch the model list or type a model id first',
  '模型 id（可手填，列表失败时用）': 'Model id (manual fallback if listing fails)',
  '例如 deepseek-v4.1-flash': 'e.g. deepseek-v4.1-flash',
  '模式一需要 API Key，模式三不需要。': 'Mode 1 needs an API key; Mode 3 does not.',
  '模式三不调用本软件 API；可预先配置，切到模式一/二后生效':
      'Mode 3 does not use the app API; you can pre-configure it for Modes 1/2.',
  '模式三不调用本软件模型；可预先配置':
      'Mode 3 does not use the app model; you can pre-configure it.',
  '检查运行环境': 'Check environment',
  '自检': 'Self-check',
  '自检中…': 'Self-check running…',
  '环境自检（检查依赖与工具是否齐全）': 'Environment self-check (dependencies and tools)',
  '最近一次 API 对话': 'Last API conversation',
  '查看 API 对话（观察/思考过程、JSON、自检、Prompt）':
      'View API conversation (observation, JSON, self-check, prompt)',
  '诊断': 'Diagnostics',
  '复制诊断信息': 'Copy diagnostics',
  '诊断信息已复制到剪贴板': 'Diagnostics copied to clipboard',
  '运行日志': 'Log',
  '日志与诊断': 'Log & diagnostics',
  '打开完整日志': 'Open full log',
  '打开日志目录': 'Open log folder',
  '日志未启用（目录不可写）': 'Logging disabled (folder not writable)',
  '当前还没有日志文件': 'No log file yet',
  '导出本次日志': 'Export this log',
  '日志已复制': 'Log copied',
  '复制日志': 'Copy log',

  // ---------- 输入面板 ----------
  '资料为主': 'Image / Material',
  '纯文本': 'Plain text',
  '点击选择编制图': 'Click to pick an ORBAT image',
  '移除': 'Remove',
  '添加图片': 'Add image',
  '选择图片': 'Choose image',
  '选择多张编制图（可多选）': 'Select ORBAT images (multi-select)',
  '选择编制资料（图片 / PDF / DOC）': 'Select source material (image / PDF / DOC)',
  '补充说明（可选）': 'Notes (optional)',
  '编制资料（纯文本）': 'Source text (plain)',
  '（直接粘贴或手打单位清单）': '(paste or type a unit list)',
  '每行一个单位，用缩进表示层级即可。': 'One unit per line; indent to indicate hierarchy.',
  '提示：模型偏好中文单位名；外文资料可在补充说明里要求保留原始缩写。':
      'Tip: the model prefers Chinese designations; for foreign material you can ask to keep original abbreviations.',
  '全中文输出（名称与注释译成中文）': 'Chinese output (designations and notes in Chinese)',
  '勾选：名称与注释输出中文（外文单位译名）':
      'Checked: output designations and notes in Chinese (translated)',
  '未勾选：名称保留原文称号/番号，注释保留原文，便于与原图对照':
      'Unchecked: keep original designations and notes for comparison with the source',
  '生成编制': 'Generate',
  '识图中': 'Reading image…',
  '识图失败': 'Recognition failed',

  // ---------- 树 / JSON 面板 ----------
  '结构': 'Tree',
  'JSON 编辑': 'JSON',
  '批量': 'Batch',
  '校验': 'Validate',
  '导出': 'Export',
  '导出编制 JSON': 'Export ORBAT JSON',
  '导出 SVG': 'Export SVG',
  '导出 PNG': 'Export PNG',
  '还没有 JSON 可导出': 'No JSON to export yet',
  '已导出 JSON': 'JSON exported',
  '还没有出图，先点「出图」': 'No image yet — render first',
  '已导出 PNG': 'PNG exported',
  'PNG 已导出': 'PNG exported',
  'SVG 已导出': 'SVG exported',
  '生成的 JSON 会出现在这里，可直接修改后点「校验」或「出图」':
      'The generated JSON appears here. Edit it directly, then Validate or Render.',
  '修改后会以文本为准出图；点「校验」可检查红牌问题':
      'Rendering uses this text; Validate to check blocking issues',
  '可以直接改下面的文本；也可以点右侧按单位改名称/注释（会同步回树）':
      'Edit the text directly, or use "Edit unit" to change names/notes (synced to the tree)',
  '按单位编辑': 'Edit unit',
  '选择一个单位': 'Select a unit',
  '按名称筛选…': 'Filter by name…',
  '编辑单位': 'Edit unit',
  '单位名称 / 番号': 'Designation / number',
  '注释': 'Note',
  '注释（驻地或职能短名）': 'Note (location or short role)',
  'SIDC（30 位数字）': 'SIDC (30 digits)',
  '编辑名称 / 注释 / 编码': 'Edit designation / note / code',
  '名称里不能有「空格+左括号」（渲染器会卡死）':
      'No space before "(" in names (it freezes the renderer)',
  '不确定就留原值；保存后会自动纠正明显不一致的位':
      'Leave as-is if unsure; obviously inconsistent bits are auto-corrected',
  '没有改动': 'No changes',
  '路径未命中，未修改（树可能已变化，请刷新后重试）':
      'Path not found — nothing changed (reload and retry)',
  '还没有编制树，先识图或载入 JSON': 'No ORBAT tree yet — generate or load a JSON first',
  '该文件不是有效的编制 JSON': 'Not a valid ORBAT JSON file',
  'JSON 解析失败，请检查语法（括号、逗号、引号）':
      'JSON parse failed — check brackets, commas and quotes',
  '还没有可出图的编制数据': 'No ORBAT data to render yet',
  '还没有校验问题': 'No validation issues',
  '清除高亮': 'Clear highlight',

  // ---------- 出图 / 预览 ----------
  '出图': 'Render',
  '出图中': 'Rendering…',
  '出图成品': 'Output',
  '白底': 'White bg',
  '开=白底 PNG；关=透明底（可叠自定义背景图）':
      'On: white background · Off: transparent (overlay your own)',
  '复制 PNG': 'Copy PNG',
  '把当前 PNG 复制到剪贴板，可直接粘贴到微信 / Word':
      'Copy the current PNG to the clipboard (paste into chat or Word)',
  '导出 PNG 到指定位置': 'Export PNG to a chosen path',
  '已复制 PNG，可直接粘贴到微信 / 文档': 'PNG copied — paste into chat or a document',
  '已复制 PNG 文件，可直接粘贴': 'PNG file copied — paste anywhere',
  '更改目录': 'Change folder',
  '打开存档目录': 'Open output folder',
  '在资源管理器里打开产物所在文件夹': 'Open the output folder in Explorer',
  '选择输出目录（JSON / PNG / SVG 保存位置）': 'Choose output folder (JSON / PNG / SVG)',
  '出图失败，详见下方日志': 'Render failed — see log below',
  '渲染脚本 render_orbat.js': 'Render script render_orbat.js',
  '出图用的线上渲染脚本绝对路径': 'Absolute path of the online render script',
  '请在设置里指定渲染脚本 render_orbat.js 的路径':
      'Set the path of render_orbat.js in Settings',
  '需要 node ≥ 24，脚本会自行探测。': 'Requires Node ≥ 24 (auto-detected).',

  // ---------- 状态 / 提示 ----------
  '有未保存的修改': 'Unsaved changes',
  '先配置 API Key': 'Configure API key first',
  '之后可随时在右上角设置里修改。': 'You can change it later in Settings.',
  '稍后再说': 'Later',
  '打开设置': 'Open settings',
  '请先在右上角设置里填写 API Key': 'Enter your API key in Settings first',
  '请截图后导入图片，或把文字粘贴到「纯文本」模式':
      'Take a screenshot and import it, or paste text in Plain-text mode',
  '纯文本模式：请先粘贴或输入编制资料': 'Plain-text mode: paste or type source text first',
  '请先选择一张编制图，或输入文字资料': 'Pick an ORBAT image, or type source text',
  '请先选择资料图片，或在补充说明里填写内容': 'Pick a source image, or fill in the notes',
  '请先添加图片': 'Add an image first',
  '已载入结果，切到「结构」查看': 'Result loaded — see the Structure tab',
  '无法读取该结果': 'Cannot read this result',
  '还没有可对比的结果（先从批量列表载入一个）':
      'Nothing to compare yet (load one from the batch list)',
  '两次结果没有差异': 'No differences between the two results',
  '还没有 API 调用记录，先生成一次编制': 'No API calls yet — generate once first',
  '还没有调用记录': 'No calls recorded',

  // ---------- 设置对话框 ----------
  '工作模式': 'Mode',
  '模式一 · 纯软件': 'Mode 1 · GUI only',
  '模式二 · 软件+CLI(配API)': 'Mode 2 · GUI + CLI (with API key)',
  '模式三 · Agent插件(无需API)': 'Mode 3 · Agent plugin (no API key)',
  '模式一：GUI 手动使用｜模式二：CLI 交给 Agent，软件配 API｜模式三：Agent 全权，软件不配 API':
      'Mode 1: manual GUI · Mode 2: CLI for agents, app holds the key · Mode 3: fully agent-driven, no key in app',
  '模式三不使用本软件的识图模型': 'Mode 3 does not use the built-in model',
  '模式三由 AI Agent 调用自己的 API，本软件不需要 Key':
      'In Mode 3 the agent calls its own API; no key needed here',
  '模式三由 Agent 决定模型': 'In Mode 3 the agent chooses the model',
  '识图模型': 'Recognition model',
  '模型 id（可手填）': 'Model id (type your own)',
  '任选预设，也可在下方手填自定义模型 id': 'Pick a preset, or type a custom model id below',
  '自定义…': 'Custom…',
  '仅存于本机配置文件（混淆存储）': 'Stored only in the local config (obfuscated)',
  'API 用量': 'API usage',
  'API 用量（调用次数 / token 消耗）': 'API usage (calls / tokens)',
  '调用次数': 'Calls',
  '输入 token': 'Input tokens',
  '输出 token': 'Output tokens',
  '合计 token': 'Total tokens',
  '清空统计': 'Clear stats',
  '清空统计？': 'Clear usage stats?',
  '会删除本机保存的全部用量记录，不可恢复。':
      'This deletes all locally stored usage records and cannot be undone.',
  // ---------- 对话查看器 ----------
  '完整响应': 'Full response',
  '复制完整响应': 'Copy full response',
  '已复制完整响应': 'Full response copied',
  '观察': 'Observation',
  '观察(思考)': 'Observation (thinking)',
  '思考链': 'Reasoning',
  '模型原生思考链（reasoning_content）：': 'Model reasoning (reasoning_content):',
  '仅 deepseek-reasoner 等模型会产生；':
      'Only produced by models like deepseek-reasoner;',
  'deepseek-flash 默认关闭，此栏通常为空。':
      'deepseek-flash disables it by default, so this is usually empty.',
  '符号集': 'Symbol set',
  '梯队': 'Echelon',
  '主实体': 'Entity',
  '类型修饰': 'Type mod',
  '机动修饰': 'Mobility mod',
  '扇区修饰': 'Sector mod',
  '陆地 (10)': 'Land (10)',
  '空中 (01)': 'Air (01)',
  '陆': 'Land',

  // ---------- 自检对话框 ----------
  '环境正常': 'Environment OK',

  // ---------- 批量 ----------
  '开始批量': 'Start batch',
  '重试这一张': 'Retry this one',
  '载入这个结果': 'Load this result',
  '清空列表': 'Clear list',
  '整理 SVG 结构': 'Tidy SVG structure',
  '· 点击已完成的结果可载入到左侧，再点「对比」看差异':
      '· Click a finished result to load it, then Compare to see differences',
  '把一个 PDF 交给视觉模型，需要逐页转成图片，':
      'Sending a PDF to a vision model means converting every page to an image,',
  'PDF / DOC 会显著增加消耗': 'PDF / DOC significantly increases token usage',
  '当前版本尚未开放 PDF/DOC 的直接解析，':
      'Direct PDF/DOC parsing is not available in this version,',
  '继续会提示你改用截图或文本。':
      'continuing will ask you to use screenshots or text instead.',

  // ---------- 结构视图 ----------
  '编制图': 'ORBAT chart',
  '标准编制图': 'ORBAT chart',

  // ---------- 带占位符的模板（tf 使用） ----------
  '已修改单位：{path}（红牌 {red}，警告 {warn}）':
      'Edited {path} (blocking {red}, warnings {warn})',
  '已保存：{path}': 'Saved: {path}',
  '已导出到 {p}': 'Exported to {p}',
  '打开失败：{e}': 'Open failed: {e}',
  '复制失败：{e}': 'Copy failed: {e}',
  '自检完成：失败 {fail} 项，警告 {warn} 项':
      'Self-check done: {fail} failed, {warn} warnings',
  '输出目录：{p}': 'Output folder: {p}',
  '输出目录：{p}（自定义）': 'Output folder: {p} (custom)',
  '{n} 个节点 · 层级 {d}': '{n} nodes · depth {d}',
  '节点 {n} · 层级 {d}': '{n} nodes · depth {d}',
  '共 {n} 个问题': '{n} issues',
  'JSON 编辑页的内容还没点「应用」，重置后会丢失。\n继续吗？':
      'The JSON tab has unapplied edits. Resetting will lose them. Continue?',
  '复制当前 PNG 到剪贴板，可直接粘贴到微信 / Word':
      'Copy the current PNG to the clipboard (paste into chat or Word)',
  '打开已有编制 JSON': 'Open an existing ORBAT JSON',
  '没有校验问题': 'No validation issues',
  '说明：出图必须联网，调用 spatialillusions.com 线上渲染器。\n需要 node ≥ 24，脚本会自行探测。':
      'Rendering requires the online renderer at spatialillusions.com.\nNode ≥ 24 is required (auto-detected).',
  '成功': 'Succeeded',
  '成功 {n}': 'Succeeded {n}',
  '把一个 PDF 交给视觉模型，需要逐页转成图片，token 消耗通常是单张图片的 3-10 倍，页数多的文件尤其明显。\n\n更省的做法：\n· 只截取需要的那一页导出为 PNG 再导入\n· 或把文字复制到「纯文本」模式\n\n当前版本尚未开放 PDF/DOC 的直接解析，继续会提示你改用截图或文本。':
      'Sending a PDF to a vision model means converting every page to an image — typically 3-10x the tokens of a single picture, worse for long documents.\n\nCheaper options:\n· Screenshot just the page you need, export as PNG and import that\n· Or paste the text into Plain-text mode\n\nDirect PDF/DOC parsing is not available in this version; continuing will ask you to use screenshots or text.',
  '识图功能需要 OpenAI 兼容 API 的 Key：\n\n1. 在 API 提供方（DeepSeek / OpenAI 等）创建 Key；\n2. 点下方「打开设置」粘贴 Key，并按需填写 API 地址与模型 id；\n3. 出图功能不需要 Key，但需要安装 Node.js 24 或更高版本。\n\n之后可随时在右上角设置里修改。':
      'Image recognition needs an OpenAI-compatible API key:\n\n1. Create a key with your provider (DeepSeek / OpenAI, etc.);\n2. Click "Open settings" below, paste the key, and set the API base URL/model id as needed;\n3. Rendering does not need a key, but requires Node.js 24 or newer.\n\nYou can change this anytime in Settings.',
  '模型原生思考链（reasoning_content）：仅 deepseek-reasoner 等模型会产生；deepseek-flash 默认关闭，此栏通常为空。':
      'Model reasoning (reasoning_content): only produced by models such as deepseek-reasoner; disabled by default in deepseek-flash, so this is usually empty.',
  '校验问题（{n}）': 'Validation issues ({n})',
  '完整日志：{p}': 'Full log: {p}',
  '模型 {m}': 'Model {m}',
  '生成后会在这里显示编制结构\n每个节点都会标注 SIDC 解读结果':
      'The ORBAT tree will appear here.\nEvery node is annotated with its SIDC.',
  'JSON 无法解析为编制树\n请切到「JSON 编辑」检查语法':
      'Cannot parse this JSON into a tree.\nCheck the syntax in the JSON tab.',
  '正在出图…\n进度见上方，完整日志在下方': 'Rendering…\nProgress above, full log below.',
  '点顶部「出图」调用线上渲染器\n需要联网，约 15-60 秒':
      'Click Render to use the online renderer.\nNeeds internet, about 15-60 seconds.',
  '正在出图': 'Rendering',
  '正在调用线上渲染器': 'Calling the online renderer',
  '页面已在后台运行，请保持网络连接（约 15-60 秒）':
      'Running in the background. Keep the network connected (about 15-60 seconds).',
  '产物已保存，正在返回主界面…': 'Output saved. Returning to the main screen…',
  '出图失败，请查看运行日志': 'Render failed. Check the run log.',
  '批量识图 + 自动出图\n\n点「添加图片」一次选多张，程序会串行处理：\n· 每张自动生成 JSON + PNG + SVG，存到图片同目录\n· 失败的可单独重试，不影响其他任务\n· 点击已完成的结果可载入到左侧，再点「对比」看差异':
      'Batch recognition + render\n\nPick several images at once; they are processed one by one:/n· Each produces JSON + PNG + SVG next to the source image\n· Failed items can be retried individually\n· Load any result afterwards to compare',
  '可补充：编制年代、番号体系、需要保留的原文缩写等。\n大图也可以给结构提示：\n总根：第1近卫机械化师\n下辖：师部、第453机械化旅、第51机械化旅':
      'Optional notes: era, numbering conventions, abbreviations to keep.\nFor large charts you can also give a structure hint:/nRoot: 1st Guards Mechanised Division\nSubordinates: HQ, 453rd Mech Brigade, 51st Mech Brigade',
  '粘贴文字资料，例如：\n第1步兵团（空中机动战斗团）\n- 指挥与勤务连\n  - 情报科\n  - 通信排\n- 轻型侦察连\n……\n\n每行一个单位，用缩进表示层级即可。':
      'Paste source text, e.g.:\n1st Infantry Regiment (air-mobile)\n- HQ & Service Company\n  - Intelligence Section\n  - Signals Platoon\n- Light Recon Company\n...\n\nOne unit per line; indent to express hierarchy.',
  '安装 Node.js 24 或更高版本（出图依赖它）':
      'Install Node.js 24 or newer (required for rendering)',
  '先用界面上的「出图」手动试一张，再看日志': 'Try Render once in the UI, then check the log',
  '先解决 Node.js，再跑自检': 'Fix Node.js first, then re-run the self-check',
  '在设置里指定渲染脚本路径': 'Set the render script path in Settings',
  '当前目录可写': 'Current folder writable',
  '跳过：没找到 Node.js': 'Skipped: Node.js not found',
  '未找到': 'Not found',
  '检查 Node.js 安装是否完整': 'Check the Node.js installation',
  '浏览器（出图用）': 'Browser (for rendering)',
  '渲染脚本': 'Render script',
  '工作目录': 'Working folders',
  '跳过：找不到 render_orbat.js': 'Skipped: render_orbat.js not found',
  'DeepSeek 接口连通': 'DeepSeek API reachable',
  '渲染站点连通': 'Render site reachable',
  '检查网络与 Node 环境；命令行手动跑 render_orbat.js 可看到完整报错':
      'Check network and Node; run render_orbat.js manually for the full error',
  'API Key': 'API key',
  '日志/快照目录可写': 'Log and snapshot folders are writable',
  '日志系统未初始化': 'Logging not initialised',
  '{ms}ms 出图成功，PNG {kb}KB': 'Rendered in {ms}ms, PNG {kb}KB',
  '产物过小（{n}B），渲染可能没画出内容': 'Output too small ({n}B) — the canvas may be empty',
  '发现 {n} 项问题': '{n} issue(s) found',
  '出图冒烟（真渲染一次）': 'Render smoke test (real render)',
  '选择使用模式': 'Choose how you will use it',
  '三种模式可随时在设置里切换；只有模式一、模式二需要 DeepSeek API Key。':
      'You can switch modes anytime in Settings. Only Modes 1 and 2 need a DeepSeek API key.',
  '桌面端三种模式可随时切换；安卓端模式二（软件+CLI）不支持。模式一需要 DeepSeek API Key，模式三不需要。':
      'Desktop supports three modes; Mode 2 (App + CLI) is not supported on Android. Mode 1 needs a DeepSeek API key; Mode 3 does not.',
  '模式二 · 软件 + CLI（安卓暂不支持）': 'Mode 2 · App + CLI (not supported on Android)',
  '请授予存储权限（Android 11+ 为「所有文件访问」）后，返回再点一次「插件处理」':
      'Grant storage access (All files access on Android 11+), then tap Plugin Processing again.',
  '在本软件界面里识图、校验、出图。需要 API Key。':
      'Recognise, validate and render inside this app. Needs an API key.',
  '模式二 · 软件 + CLI': 'Mode 2 · App + CLI',
  '软件里配 Key，命令行 orbat-cli 供脚本 / Agent 调用。需要 API Key。':
      'The app holds the key; scripts or agents drive orbat-cli. Needs an API key.',
  '模式三 · Agent 插件（无需 API Key）': 'Mode 3 · Agent plugin (no API key)',
  '用 orbat-cli prompts 导出提示词交给外部 Agent 识图；本软件不配 Key。':
      'Export prompts with orbat-cli prompts and let an external agent recognise the chart; no key stored here.',
  '模式三：不需要 API Key': 'Mode 3: no API key needed',
  '本软件不会向你要 Key。工作方式是：\n\n1. 用 orbat-cli prompts 导出识图提示词；\n2. 把提示词和图交给你的 Agent（它用自己的模型）；\n3. 把 Agent 产出的 JSON 贴回本软件，校验与出图仍然可用。\n\n之后想在界面里直接识图，随时在设置里切到模式一/二并填写 Key。':
      'This app will not ask for a key. How it works:/n/n1. Export the recognition prompt with orbat-cli prompts;\n2. Hand the prompt and image to your agent (it uses its own model);\n3. Paste the JSON back here — validation and rendering still work.\n\nIf you later want in-app recognition, switch to Mode 1/2 in Settings and add a key.',
  '模式三由外部 Agent 识图，本软件不配 Key；要在界面识图请切到模式一/二并填写 Key':
      'In Mode 3 an external agent does the recognition and this app holds no key; switch to Mode 1/2 and add a key to recognise here.',
  '选择使用模式（可随时在设置里切换，只有模式一/二需要 Key）':
      'Choose a mode (switchable in Settings; only Modes 1/2 need a key)',
  '选择界面语言': 'Choose interface language',
  '简体中文界面': 'Simplified Chinese interface',
  '继续': 'Continue',
  '检测到系统语言 {loc}，已默认选中对应语言；之后可随时在设置里更改。':
      'System language detected: {loc}. The matching language is pre-selected; you can change it anytime in Settings.',
  '使用教程': 'Tutorial',
  '内置教程（纯文字，随界面语言切换）': 'Built-in tutorial (text only, follows UI language)',
  '查看内置教程（纯文字）': 'Open built-in tutorial (text)',
  '纯文字版，随界面语言切换；完整图文教程见发布页的 doc 文档。':
      'Text-only version, follows the UI language. The illustrated tutorial is in the doc file on the release page.',
  '复制全文': 'Copy all',
  '教程全文已复制到剪贴板': 'Tutorial copied to clipboard',
};

/// 模板 key 以 `{name}` 形式写在 _en 里，由 tf() 替换占位符。
