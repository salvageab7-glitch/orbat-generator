/// 内置纯文字教程（随界面语言切换，GUI 教程窗口与 CLI `tutorial` 命令共用）
///
/// 为什么不放 assets：`core` 与 `cli` 也要用（CLI 的 AOT 包不带 Flutter asset 机制），
/// 纯 Dart 常量最省事，也不会出现"打包漏了资源文件、教程点开是空白"。
///
/// 维护约定：这里只写**操作路径**，不写营销话术。功能改了要同步改，
/// 否则用户会照着一份过时的说明操作，比没有教程更糟。
library;

import 'l10n.dart';

/// 按当前界面语言取教程正文
String tutorialText() => L10n.isEn ? kTutorialEn : kTutorialZh;

/// 教程版本标记（与界面版本对应，方便用户/客服确认看的是哪一版说明）
const String kTutorialRevision = 'v0.3.5';

const String kTutorialZh = '''
编制图生成器 · 内置教程（$kTutorialRevision）

────────────────────────────
一、这个软件做什么
────────────────────────────
把编制图（组织架构图 / 军标标图）自动变成结构化 JSON，再用军标符号重新出图。
输入可以是图片，也可以是文字（把编制表贴进来）。

────────────────────────────
二、三种使用模式（第一次启动会让你选，之后可在设置里改）
────────────────────────────
模式一 · 纯软件
  在本软件界面里识图、校验、出图。需要 DeepSeek API Key。
模式二 · 软件 + CLI（仅桌面端；Android 不支持）
  软件里配 Key，命令行 orbat-cli 交给脚本或 Agent 调用。需要 API Key。
模式三 · Agent 插件
  用 orbat-cli prompts 导出提示词，交给外部 Agent 识图；
  本软件不配 Key，但校验、编辑、出图照常可用。

只有模式一、模式二需要 API Key；模式二仅桌面端。模式三完全不需要。

────────────────────────────
三、配置 API Key（模式一 / 二）
────────────────────────────
1. 打开 platform.deepseek.com 注册并登录；
2. 左侧「API keys」→ 创建，复制 sk- 开头的密钥；
3. 回到软件，右上角齿轮 → 设置 → 粘贴到「DeepSeek API Key」→ 保存。

Key 用 Windows DPAPI 加密保存，只有同一台电脑、同一个 Windows 账户能解开。
换电脑或重装系统后需要重新填一次，这是正常现象，不是出错。
界面和日志里只显示指纹（如 sk-68d…），不会明文回显。

────────────────────────────
四、识图与出图（模式一）
────────────────────────────
1. 顶栏「选择图片」→ 选一张编制图（PNG / JPG）。
2. 左侧可写补充说明：编制年代、番号体系、要保留的原文缩写；
   大图也可以直接给结构提示，例如：
   总根：第1近卫机械化师
   下辖：师部、第453机械化旅、第51机械化旅
3. 点「生成编制」。程序会切块识图 → 合并 → 一致性审计 → 校验。
4. 中栏「结构」看编制树，「JSON 编辑」看原始数据。
   有红牌问题会在顶部提示，可按提示改，也可让程序再做一轮补丁式修复。
5. 点「出图」调用线上渲染器（需要联网，约 15-60 秒），产出 PNG / SVG / JSON。

────────────────────────────
五、看结果时重点看什么
────────────────────────────
· 层级有没有多一层或少一层（最常见的错）。
   图上只画到营，就不要出现连；反之亦然。
· 有没有把「旅部及旅部连」这类直属分队挂到某个营下面（应为平级）。
· 单位名称是否照抄原文，型号 / 口径 / 数量是否进了注释。
· 符号大小是否与层级匹配（营的符号应比连大一号）。

────────────────────────────
六、改单位：名称 / 注释 / 编码
────────────────────────────
两个入口：
· 「结构」页每行右侧的铅笔图标；
· 「JSON 编辑」页右上「按单位编辑」（长树里可搜索，更快）。

可改三项：单位名称 / 番号、注释、SIDC（30 位军标码）。
改完自动重跑机械修复与校验，JSON 文本与问题清单同步刷新。

注释规则：不超过 12 个汉字（英文 20 个字母），只写驻地或职能短名，
不写指挥官姓名。超限会提示并按上限截断。

────────────────────────────
七、产物放在哪
────────────────────────────
默认在「软件目录\\输出文件存档」。
出图后可点「复制 PNG」直接粘到微信 / Word，或点「打开存档目录」跳过去。
安装到 Program Files 且无写权限时，会自动退到「我的文档\\输出文件存档」。
目录可在设置里改。

────────────────────────────
八、批量处理
────────────────────────────
「批量」页 → 添加图片（可多选）→ 串行处理，每张自动产出 JSON + PNG + SVG，
存在图片同目录。失败的可以单独重试，不影响其他任务。
点已完成的结果可载入到左侧，再点「对比」看与原图的差异。

────────────────────────────
九、模式三：交给外部 Agent
────────────────────────────
1. orbat-cli prompts --out 提示词.txt    导出识图提示词；
2. 把提示词和图片交给你的 Agent（它用自己的模型）；
3. 把 Agent 产出的 JSON 存成文件，用本软件「打开已有编制 JSON」载入；
4. 之后校验、改单位、出图都能正常用。
这条路径不需要本软件持有任何 Key。

────────────────────────────
十、命令行速查（orbat-cli.exe）
────────────────────────────
selfcheck [--smoke]          环境自检；--smoke 真渲染一张小图验证出图链路
generate --image 图.png      识图并生成 JSON（--raw-names 保留原文）
generate --text 资料.txt     从文字资料生成
render --in 编制.json         出图
validate 编制.json           结构校验（有红牌时 exit=3）
audit --in 编制.json         一致性审计：模型码与名称冲突时给建议值
edit --in 编制.json --path "根/第1旅/第2营" --name/--note/--sidc [--out]
                             按路径改单个单位
batch --dir 图片目录          批量处理
tutorial                     打印这份教程（--lang en 输出英文）
所有命令加 --help 可看参数。

────────────────────────────
十一、常见问题
────────────────────────────
问：点了「生成编制」没反应？
答：先看右上角「自检」。九项里最后一项是出图冒烟，它失败通常是
    网络到不了渲染站点或 Node 版本过低。识图失败则多在 Key（401/402）。

问：注释被自动截短了？
答：注释上限 12 汉字 / 20 字母，驻地建议用简写。

问：符号是个方块或不显示？
答：SIDC 的符号集或实体码不对。用「按单位编辑」看该节点的编码，
    或跑 audit 看建议值。

问：换电脑后提示 Key 无效？
答：DPAPI 绑定本机与本账户，重新填一次即可。

问：设置改完重启又变回去？
答：受控环境（公司电脑）可能禁止写 %APPDATA%\\OrbatGenerator，
    日志里会有「WARN [config] 写入 config.json 失败」。

问：界面想换语言？
答：设置 → 界面语言 → 跟随系统 / 中文 / English，切换后立即生效，
    这份教程也会跟着切换。

────────────────────────────
十二、隐私说明
────────────────────────────
· API Key 只存在本机 %APPDATA%\\OrbatGenerator\\config.json，DPAPI 加密；
· 图片与文本只发送到你配置的模型服务（默认 api.deepseek.com）；
· 出图会把 JSON 发到 spatialillusions.com 的线上渲染器；
· 本软件不收集、不上传任何使用数据。
''';

const String kTutorialEn = '''
ORBAT Generator · Built-in tutorial ($kTutorialRevision)

────────────────────────────
1. What it does
────────────────────────────
Turns an order-of-battle chart (org chart or military symbology) into structured
JSON, then renders it again with standard unit symbols.
Input can be an image, or text pasted from a table.

────────────────────────────
2. Three ways to use it (chosen on first launch, changeable in Settings)
────────────────────────────
Mode 1 · Standalone app
  Recognise, validate and render inside this app. Needs a DeepSeek API key.
Mode 2 · App + CLI (desktop only; not supported on Android)
  The app holds the key; scripts or agents drive orbat-cli. Needs an API key.
Mode 3 · Agent plugin
  Export prompts with orbat-cli prompts and let an external agent recognise the
  chart. No key stored here, but validation, editing and rendering still work.

Only Modes 1 and 2 need an API key; Mode 2 is desktop-only. Mode 3 needs none.

────────────────────────────
3. Set up an API key (Modes 1 / 2)
────────────────────────────
1. Sign up at platform.deepseek.com;
2. "API keys" → create one, copy the sk-... string;
3. In the app: gear icon → Settings → paste into "DeepSeek API Key" → Save.

The key is stored with Windows DPAPI: only the same machine and the same Windows
account can decrypt it. After changing machine or reinstalling Windows you must
enter it again — that is expected, not an error.
The UI and logs only ever show a fingerprint (e.g. sk-68d...).

────────────────────────────
4. Recognise and render (Mode 1)
────────────────────────────
1. Top bar "Select image" → pick a chart (PNG / JPG).
2. The left panel accepts notes: era, numbering conventions, abbreviations to
   keep. For large charts you can also give a structure hint, e.g.
   Root: 1st Guards Mechanised Division
   Subordinates: HQ, 453rd Mech Brigade, 51st Mech Brigade
3. Click "Generate". The app tiles the image, recognises each tile, merges,
   audits name/code consistency, then validates.
4. The middle "Tree" tab shows the structure; "JSON" shows the raw data.
   Blocking issues appear at the top; fix them by hand or let the app apply a
   patch-style repair round.
5. Click "Render" to use the online renderer (needs internet, 15-60 s) and
   produce PNG / SVG / JSON.

────────────────────────────
5. What to check in the result
────────────────────────────
· Depth: one level too many or too few is the most common error.
  If the chart stops at battalion, there should be no companies.
· Direct-support units (HQ company, signals, engineers) must stay siblings of
  the battalions, not be nested under one of them.
· Names copied verbatim; model, calibre and quantity belong in the note.
· Symbol size should match the echelon (battalion larger than company).

────────────────────────────
6. Edit a unit: name / note / code
────────────────────────────
Two entry points:
· the pencil icon at the end of each row in the "Tree" tab;
· "Edit by unit" at the top right of the "JSON" tab (searchable, faster on
  large trees).
You can change the designation, the note and the SIDC (30-digit code).
Saving re-runs the automatic fixes and validation; the JSON text and the issue
list refresh together.

Note rule: at most 12 CJK characters (20 letters in English), location or a
short function only, never a commander's name. Over-long notes are flagged and
truncated.

────────────────────────────
7. Where the output goes
────────────────────────────
By default: "<app folder>\\输出文件存档".
After rendering you can click "Copy PNG" to paste into chat or Word, or "Open
archive folder" to jump there.
If the install folder is not writable (e.g. Program Files), it falls back to
"Documents\\输出文件存档". The folder is configurable in Settings.

────────────────────────────
8. Batch processing
────────────────────────────
"Batch" tab → add images (multi-select) → processed one by one, each producing
JSON + PNG + SVG next to the source image. Failed items can be retried
individually. Click a finished item to load it on the left, then "Compare".

────────────────────────────
9. Mode 3: hand it to an external agent
────────────────────────────
1. orbat-cli prompts --out prompt.txt      export the recognition prompt;
2. give the prompt and the image to your agent (it uses its own model);
3. save the agent's JSON and load it with "Open existing ORBAT JSON";
4. validation, editing and rendering then work as usual.
This path requires no key in this app.

────────────────────────────
10. CLI quick reference (orbat-cli.exe)
────────────────────────────
selfcheck [--smoke]          environment check; --smoke renders a tiny chart
generate --image chart.png   recognise an image (--raw-names keeps original text)
generate --text notes.txt    build from text material
render --in orbat.json       render
validate orbat.json          structural validation (exit=3 on blocking issues)
audit --in orbat.json        consistency audit: suggests codes from names
edit --in orbat.json --path "root/1st Bde/2nd Bn" --name/--note/--sidc [--out]
                             patch a single unit
batch --dir images           batch process a folder
tutorial                     print this tutorial (--lang zh for Chinese)
Add --help to any command for its parameters.

────────────────────────────
11. FAQ
────────────────────────────
Q: Clicked "Generate" and nothing happens.
A: Run "Self-check" first. Its last item is a real render smoke test; failure
   there usually means the render site is unreachable or Node is too old.
   Recognition failures are usually the key (401/402).

Q: My note got truncated.
A: Notes are capped at 12 CJK characters / 20 letters; use abbreviations.

Q: The symbol is a blank box.
A: The SIDC symbol set or entity is wrong. Inspect the node's code with
   "Edit by unit", or run audit for the suggested value.

Q: After moving to another PC the key is rejected.
A: DPAPI is bound to that machine and account. Enter the key again.

Q: My settings revert after restart.
A: Managed environments may block writes to %APPDATA%\\OrbatGenerator.
   The log shows "WARN [config] 写入 config.json 失败".

Q: How do I change the interface language?
A: Settings → Interface language → System / 中文 / English. It applies
   immediately, including this tutorial.

────────────────────────────
12. Privacy
────────────────────────────
· The API key lives only in %APPDATA%\\OrbatGenerator\\config.json, DPAPI-encrypted.
· Images and text are sent only to the model service you configured
  (api.deepseek.com by default).
· Rendering sends the JSON to the online renderer at spatialillusions.com.
· The app collects and uploads no usage data.
''';
