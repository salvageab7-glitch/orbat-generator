# ORBAT Agent Tools

English | [简体中文](#简体中文)

A local DSH Desktop bundle that gives an AI agent tools and adds an in-app Settings page for ORBAT workflow preferences:

- `orbat_validate_json` checks the complete JSON tree and returns bounded, structured issues.
- `orbat_render_json` validates and normalizes the tree, refuses red-card input, then renders PNG/SVG through the included Node scripts and the installed or privately provisioned Node.js runtime.
- `orbat_workflow_self_check` runs the same validation, Node/browser renderer and cleanup workflow as the Settings page; it does not require an API key.

The **Settings → ORBAT** page lets users choose white or transparent PNG output, set or restore the default output directory, and run a workflow self-check. SVG exports are always transparent. The page uses DSH's Client settings slot and its settings are stored in a small user-level LocalAppData file.

The plugin does **not** call an AI API or need a DeepSeek API key. The agent uses its own model and image-reading capability to draft JSON, then calls the tools. After a successful render, call DSH's `present` tool with the returned `pngPath` to show the result. New agents should read [`AGENT-GUIDE.md`](AGENT-GUIDE.md) for the JSON shape, SIDC guardrails, and source-faithful image workflow.

## Requirements

- Windows x64 and a DSH Desktop build that supports Host bundles with the native `tools`, `subprocess`, and `webServer` services plus Client settings-section slots. The adapter uses DSH-injected Host APIs and has no runtime import from DSH packages; the Client page uses the installed settings and locale modules.
- Windows x64. An existing Node.js 24+ at `C:\Program Files\nodejs\node.exe` or on `PATH` is optional: if none is found, the plugin downloads the pinned official Node.js v24.22.3 Windows x64 ZIP on first render, verifies its SHA-256, and extracts only `node.exe` plus its `LICENSE` under `%LOCALAPPDATA%\OrbatGeneratorDshPlugin\Node`. It needs no administrator rights and does not modify `PATH` or a system installation.
- Google Chrome or Microsoft Edge for headless rendering.
- Network access to `https://nodejs.org` for first-use runtime setup when Node 24+ is absent, and `https://spatialillusions.com/unitgenerator` during rendering. The browser imports the ORBAT JSON into that public page; review the renderer's privacy terms if your data policy changes.

The DSH subprocess adapter starts the fixed validation CLI and Node renderer directly with explicit argument vectors (no shell command construction), using a small environment allowlist. It does not forward `DEEPSEEK_API_KEY`; CLI settings and browser profiles are isolated under `%LOCALAPPDATA%\OrbatGeneratorDshPlugin` so the plugin does not read or rewrite the desktop app's own settings. Input JSON is limited to 10 MiB. Output defaults to `编制插件产物仓库` under the current session workspace; a non-empty absolute Windows directory in **Settings → ORBAT** overrides it, and the default falls back to `Documents\ORBAT Generator` then `%LOCALAPPDATA%\OrbatGeneratorDshPlugin\Output` when needed. A configured custom directory fails clearly rather than silently writing elsewhere.

## Agent workflow

1. Read the supplied image/document using the agent's own vision or file tools and draft the application's ORBAT JSON schema. The plugin does not interpret source images.
2. Call `orbat_validate_json` with either the entire JSON string (`json`) or a file path (`path`). Prefer `path` after writing the file: it avoids re-emitting a large tree on every call. Use the returned issue paths/messages to correct structural or SIDC errors; do not suppress validation failures by changing labels alone.
3. Call `orbat_render_json` after correction, again preferring `path` over inline `json`. It revalidates and will not render when red issues remain. Warnings are reported but do not by themselves block rendering.
4. On success, call `present` with the exact returned `pngPath` (and optionally the SVG path) so the user sees the actual file.

The tool output is bounded: at most 50 validation issues are returned, with `issueCount` and `issuesTruncated` indicating whether more exist. Validation uses the CLI's single-JSON stdout protocol; the render tool verifies the expected PNG/SVG files after the bundled renderer exits.

## Install a local checkout

This bundle is intended to be installed through DSH Plugin Manager, not by copying files into the DSH profile manually:

1. Build or obtain the complete Windows release folder containing `package.json`, `index.js`, `client.js`, `lib/`, `locale/`, `AGENT-GUIDE.md`, `CLI-PROTOCOL.md`, `THIRD-PARTY-NOTICES.md`, `icon.svg`, `cordis.patch.yml`, `orbat-cli.exe`, and `runtime/`.
2. In DSH Desktop, use Plugin Manager's **Install bundle** action and select the extracted bundle directory.
3. Start a new session, confirm the three ORBAT tools and **Settings → ORBAT** page appear, validate a small JSON fixture, then render a known-good fixture and present the PNG.
4. Open the ORBAT Settings page, change the PNG background and output directory, save, and run the self-check.

Do not treat a successful install status as proof that the tools or Client page work. The bundle does not alter the DSH profile until installed.

## Portability

The CLI JSON protocol is documented in [`CLI-PROTOCOL.md`](CLI-PROTOCOL.md). Other agent hosts can reuse the standalone CLI for validation/normalization and the included Node renderer directly, then provide their own runtime provisioning, managed-process, cancellation, and file-presentation adapters. The DSH-specific layer is `index.js` plus the Client settings entry in `client.js`; `lib/preferences.js` owns the small HTTP/file settings adapter. MCP is intentionally not required.

## Current release status

This is the `0.3.6` public release bundle, built for the DSH `0.2.2-rc.5` plugin contract and published with the ORBAT Generator `0.3.6` desktop release. It includes the Settings page for PNG background/output directory, the shared workflow self-check, path-based validation/rendering, the 0.3.6 SIDC/echelon fixes, and the default workspace `编制插件产物仓库` output policy. It uses an existing Node.js 24+ installation when available; otherwise it downloads pinned Node.js `v24.22.3`, verifies the archive and executable SHA-256 values, and keeps the binary and upstream `LICENSE` in the current user's LocalAppData. The Host settings route, settings persistence, self-check workflow, Client registration/localization, workspace output, path input, HQ echelon fallback, and PNG/SVG rendering have been verified.

---

# 简体中文

这是一个供 DSH Desktop 使用的本机插件，提供一个设置页面和三个 AI Agent 工具：

- `orbat_validate_json`：校验完整 ORBAT JSON，并返回有数量上限的结构化问题列表。
- `orbat_render_json`：校验并归一化编制树；有红牌时拒绝出图；通过后用随包 Node 脚本和本机或自动安装的 Node.js 运行时输出 PNG/SVG。
- `orbat_workflow_self_check`：运行与设置面板相同的工作流自检，不需要 API Key。

在 **设置 → 编制图** 中可以切换 PNG 白底/透明背景、设置或恢复默认输出目录，并运行自检。SVG 导出始终透明。

插件本身不调用 AI API，也不需要 DeepSeek API Key。Agent 使用自己的模型和读图能力生成 JSON，再调用插件工具。渲染成功后，请使用 DSH 的 `present` 工具展示返回的 `pngPath`。新用户Agent请先阅读 [`AGENT-GUIDE.md`](AGENT-GUIDE.md)，了解JSON结构、SIDC边界和忠实来源的读图流程。

## 依赖

- Windows x64，以及支持 Host bundle 和原生 `tools`、`subprocess`、`webServer` 服务及 Client settings-section slot 的 DSH Desktop。适配层使用 DSH 注入的 Host API，不在运行时导入 DSH 包。
- Windows x64。系统中已有的 Node.js 24+（如 `C:\Program Files\nodejs\node.exe` 或 PATH）不是必需条件：若未找到兼容版本，插件会在首次出图时从 Node.js 官方站点下载固定的 v24.22.3 Windows x64 ZIP，校验 SHA-256 后仅提取 `node.exe` 和其 `LICENSE`，保存在 `%LOCALAPPDATA%\OrbatGeneratorDshPlugin\Node`。无需管理员权限，也不会修改 PATH 或系统安装。
- Google Chrome 或 Microsoft Edge，用于无头渲染。
- 若缺少 Node 24+，首次运行需访问 `https://nodejs.org`；出图时还需访问 `https://spatialillusions.com/unitgenerator`。浏览器会把 ORBAT JSON 导入该公开页面；若数据策略有变化，请重新核对渲染器隐私条款。

DSH 子进程适配器通过固定 argv 分别启动校验 CLI 和 Node renderer，不经过 shell，并只传递少量明确允许的环境变量，不转发 `DEEPSEEK_API_KEY`。CLI 配置与浏览器临时profile隔离在 `%LOCALAPPDATA%\OrbatGeneratorDshPlugin`，不会读取或改写桌面应用自身的设置。输入 JSON 上限为 10 MiB。输出默认保存至当前会话工作区下的 `编制插件产物仓库`；在 **设置 → 编制图** 中填写的绝对目录优先，默认目录不可写时才回退到 `Documents\ORBAT Generator`，再回退到 `%LOCALAPPDATA%\OrbatGeneratorDshPlugin\Output`。自定义目录不可用时会明确失败。

## Agent 使用流程

1. Agent 使用自己的视觉/文件工具读取用户提供的图片或资料，并按应用的 ORBAT JSON schema 生成草稿；本插件不负责识别源图片。
2. 将完整 JSON 文本（`json`）或文件路径（`path`）交给 `orbat_validate_json`。文件已落盘时优先用 `path`，避免每次调用都重发整棵树。根据返回的问题路径和说明修复结构或 SIDC 错误，不要只改标签来掩盖校验失败。
3. 修复后调用 `orbat_render_json`，同样优先用 `path` 而非内联 `json`。该工具会再次校验；仍有红牌时不会出图。警告会报告，但本身不阻止渲染。
4. 成功后使用 `present` 工具展示返回的 PNG 路径（也可同时展示 SVG）。

工具结果最多返回 50 条校验问题，并用 `issueCount`、`issuesTruncated` 表明是否还有未展示的问题。CLI stdout 是单个 JSON 对象，诊断信息写入 stderr。

## 本地安装

通过 DSH Plugin Manager 安装，不要手动向 DSH profile 目录复制文件：

1. 准备完整 Windows 发布目录，包含 `package.json`、`index.js`、`client.js`、`lib/`、`locale/`、`AGENT-GUIDE.md`、`CLI-PROTOCOL.md`、`THIRD-PARTY-NOTICES.md`、`icon.svg`、`cordis.patch.yml`、`orbat-cli.exe` 和 `runtime/`。
2. 在 DSH Desktop 的 Plugin Manager 中使用 **Install bundle**，选择解压后的插件目录。
3. 新建会话，确认三个 ORBAT 工具和 **设置 → 编制图** 页面出现；用小型 JSON 测试校验，再用已知可渲染 JSON 出图并展示 PNG。
4. 在设置页面更改 PNG 背景和输出目录、保存，并运行工作流自检。

安装状态成功不代表工具或 Client 页面已可用；未安装时不会改动 DSH profile。

## 移植

独立 CLI JSON 协议见 [`CLI-PROTOCOL.md`](CLI-PROTOCOL.md)。其他 Agent Host 可复用独立 CLI 的校验/归一化能力，并直接调用随附 Node renderer；需自行实现运行时配置、受管进程、取消及文件展示适配。DSH 专属部分包括 `index.js` Host 工具、`client.js`设置页面及`lib/preferences.js`偏好路由；随包 Windows CLI 仅适用于 Windows。首版不依赖 MCP。

## 当前状态

这是 `0.3.6` 公开版插件包，基于当前 DSH `0.2.2-rc.5` 插件契约，并与 ORBAT Generator `0.3.6` 桌面版一同发布。本版本包含设置页面（PNG 背景和默认输出目录）、与 Agent 自检工具共用的工作流检查、`path` 文件输入、0.3.6 的 SIDC/梯队修正，以及默认写入会话工作区 `编制插件产物仓库` 的策略。若系统没有 Node.js 24+，插件会从 Node.js 官方站点下载固定的 `v24.22.3`，校验归档和可执行文件 SHA-256，并将二进制及上游 `LICENSE` 保存在当前用户的 LocalAppData。Host 设置路由、设置持久化、自检工作流、Client 注册/语言、工作区落盘、path 输入、HQ 梯队兜底和 PNG/SVG 渲染均已验证。
