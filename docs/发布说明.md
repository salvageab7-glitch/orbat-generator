# 编制生成器 v0.3.6 公开测试版

从编制结构图或文字资料，AI 识图生成标准军标编制 JSON（SIDC 30 位码），再调用线上渲染器产出编制图（PNG + SVG）。

> 这是 0.3.6 的公开测试构建。欢迎试用与反馈；接口和文件格式仍可能调整。

## 本版亮点

- **梯队与 HQ 修正**：名称带 `·` 时按“第1营·第327步兵团”识别为营级；师部及师部营按营级 16 处理。手工编辑或导入的 JSON 在出图前会自动修正 HQ 梯队码，但只影响本次渲染，源 JSON 不被改写。
- **校验口径统一**：注释上限统一为 12 个汉字 / 20 个字母；提示词、校验器、修复逻辑使用同一套规则。
- **CLI 更完整**：新增 `--version`、`config.version`、`parse/validate/normalize --in`；`edit` 支持 stdin 管道；`render` 失败时顶层 `ok=false`；`normalize --adapt-for-render` 返回 `echelonFixed`；`audit --strict` 可把红牌变成 exit 3。
- **DSH 插件 0.3.6**：`orbat_validate_json` / `orbat_render_json` 支持 `path` 文件输入，避免反复粘贴大 JSON；默认输出到会话工作区的 `编制插件产物仓库`；渲染日志降噪；技能拆成 L1 快卡 + L2 参考手册。
- **技能与文档**：`AGENT-GUIDE.md`、`CLI-PROTOCOL.md`、`README.md` 与 0.3.6 行为同步。

## 下载

| 附件 | 说明 |
|---|---|
| `orbat-generator-v0.3.6-full-setup.exe` | **完整版安装器**（推荐）：内置 Node.js，免装 Node；自动检测并安装 VC++ 运行库 |
| `orbat-generator-v0.3.6-lite-setup.exe` | 精简版安装器：体积小；出图需自装 Node.js ≥ 24 |
| `orbat-generator-v0.3.6-android-debug.apk` | 安卓端（实验性）：debug 签名，插件交接模式；不是应用商店版本 |
| `orbat-agent-v0.3.6-dsh-plugin.zip` | DSH Desktop 插件包：解压后用 Plugin Manager 的 Install bundle 选择目录 |
| `orbat-agent-v0.3.6-dsh-plugin.tgz` | DSH 插件的 npm 包形式，供命令行安装或离线分发 |
| `SHA256SUMS.txt` | 上述附件的 SHA-256 校验值 |

## 环境要求

- Windows 10 / 11（64 位）；Android 7.0+（API 24）
- Edge 或 Chrome（Windows 自带 Edge 即可）
- Node.js ≥ 24（**仅精简版需要**；完整版已内置）
- DeepSeek API Key（模式一/模式二识图需要；模式三不需要）
- 网络：可访问 deepseek.com 与 spatialillusions.com

## 安装与升级

### Windows

1. 运行 `full-setup`（推荐）或 `lite-setup`。
2. 安装器会创建桌面快捷方式；首次启动按向导选择语言与模式。
3. 出图报错时先运行「环境自检」。

安装包未做商业代码签名，Windows SmartScreen 可能提示“未知发布者”；请核对下载来源与 SHA-256。

### Android

APK 使用 Android debug 签名，仅用于公开测试，不能上架应用商店。若设备上已安装旧版且签名不同，请先卸载旧版再安装。安装后按《安卓端Agent插件指导.md》配置交接目录。

### DSH 插件

ZIP 解压后，在 DSH Desktop 的 **Plugin Manager → Install bundle** 选择解压目录。插件需要 DSH Desktop 0.2.2-rc.5 或兼容版本；首次出图若没有 Node 24+，会下载固定版本 Node 并校验 SHA-256。

## 已知问题

- Android 为 debug 签名，属于实验性构建；未做 release 签名与商店适配。
- Windows 安装器和主程序未做代码签名，可能出现 SmartScreen 提示。
- 渲染布局最右列的超长标签可能贴边裁切；这是线上渲染器的排版限制，后续处理。
- 插件渲染依赖 `spatialillusions.com`；该站点不可用时无法出图。

## 校验

下载后可在 PowerShell 中核对：

```powershell
Get-FileHash .\orbat-generator-v0.3.6-full-setup.exe -Algorithm SHA256
```

所有附件的校验值见 Release 附件中的 `SHA256SUMS.txt`。如果哈希不一致，请勿运行安装包。

## 反馈

遇到问题请附上报错截图与日志（`%APPDATA%\OrbatGenerator\logs\`），通过 Issue 反馈。

## 开源

MIT License · 署名 LStR-40
