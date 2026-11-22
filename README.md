# 编制生成器 / ORBAT Generator

把编制结构图或文字资料，通过 DeepSeek 转写成结构化 ORBAT JSON，再调用线上渲染器出图。支持 Windows、Android，并附带 DSH Desktop Agent 插件。

当前版本：**0.3.6 公开测试版**。

## 功能概览

- 识图 / 文字 → ORBAT JSON（DeepSeek 视觉，分块识图 + 结构合并）
- 本地规则引擎生成/校正 30 位 SIDC，并做名称—码一致性审计
- 红牌校验 + 补丁式修复（不重写整棵树，避免丢节点）
- 调用线上渲染器出 PNG/SVG
- 树视图就地编辑名称、注释、编码
- 中英双语界面与教程
- 模式三：外部 Agent 识图，无需 API Key
- CLI（`orbat-cli.exe`）供外部 Agent 调用
- DSH Desktop 插件：`orbat_validate_json` / `orbat_render_json` / `orbat_workflow_self_check`

## 0.3.6 重点改动

- 名称梯队解析修正：`第1营·第327步兵团` 按营级处理
- 师部及师部营等 HQ 节点：出图前自动修正梯队码，仅影响本次渲染，源 JSON 不变
- 注释上限统一为 12 汉字 / 20 字母，提示词、校验器、修复逻辑一致
- CLI 新增 `--version`、`config.version`、`validate/normalize/parse --in`；`edit` 支持 stdin；`render` 失败返回顶层 `ok=false`；`audit --strict` 红牌 exit 3
- DSH 插件支持 `path` 输入、默认输出到会话工作区 `编制插件产物仓库`、渲染日志降噪
- Agent 技能拆分为 L1 快卡 + L2 参考手册

## 下载

请到 [Releases](https://github.com/salvageab7-glitch/orbat-generator/releases) 下载：

| 附件 | 说明 |
|---|---|
| `orbat-generator-v0.3.6-full-setup.exe` | 完整版安装器，内置 Node.js 与 VC++ 运行库检测 |
| `orbat-generator-v0.3.6-lite-setup.exe` | 精简版安装器，出图需自装 Node.js ≥ 24 |
| `orbat-generator-v0.3.6-android-debug.apk` | 安卓端实验性构建，debug 签名 |
| `orbat-agent-v0.3.6-dsh-plugin.zip` | DSH Desktop 插件包，解压后用 Plugin Manager 安装 |
| `orbat-agent-v0.3.6-dsh-plugin.tgz` | DSH 插件的 npm 包形式 |

## 目录结构

```
lib/                 # Flutter / 纯 Dart 源码
  core/              # 规则引擎、SIDC、数据模型、校验、自动修复
  ai/                # 提示词与 DeepSeek 客户端
  render/            # 线上渲染器调用
  cli/               # orbat-cli 源码
  ui/                # 主界面与树视图
  pipeline.dart      # 业务编排
windows/             # Windows Runner
android/             # Android 工程
cli_aot/             # CLI AOT 构建副本
runtime/             # Node 渲染脚本
test/                # 单元测试、引擎自检、端到端测试
docs/                # 发布说明、CLI/模式三/安卓文档
dsh-orbat-plugin/    # DSH Desktop 插件源码与打包产物
```

## 环境要求

| 项 | 要求 | 用途 |
|---|---|---|
| Flutter | 3.50+ | 构建 Windows / Android |
| Visual Studio | 2022 生成工具 + C++ 工作负载 | Windows 构建 |
| Node.js | ≥ 24 | 出图 |
| Chrome / Edge | 近期版本 | 出图时驱动 |
| Android SDK / JDK 17 | API 36 / Temurin 17 | Android 构建 |
| DeepSeek API Key | — | 模式一/二识图 |

## 构建

### Windows

> 中文路径会导致 `flutter build windows --release` 在 Dart AOT 阶段失败。请复制到纯 ASCII 路径构建。

```bash
flutter pub get
flutter build windows --release
```

把 `runtime/` 复制到 `build/windows/x64/runner/Release/` 后再分发。

### Android

```bash
flutter build apk --debug      # 公开测试用 debug 签名
# 或
flutter build apk --release    # 需设置 ORBAT_RELEASE_* 四个环境变量
```

Release 签名环境变量：`ORBAT_RELEASE_KEYSTORE`、`ORBAT_RELEASE_STORE_PASSWORD`、`ORBAT_RELEASE_KEY_ALIAS`、`ORBAT_RELEASE_KEY_PASSWORD`。四项必须全部设置；请勿把 keystore 或密码提交到仓库。

### CLI

```bash
dart compile exe cli_aot/lib/cli/main.dart -o orbat-cli.exe
orbat-cli.exe --version
```

### DSH 插件

```bash
cd dsh-orbat-plugin
npm pack
```

## 测试

```bash
flutter test
dart run test/engine_selfcheck.dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_cli_contract.ps1
```

`test_cli_contract.ps1` 覆盖 10 个进程级 CLI 契约用例。

## DSH 插件安装

1. 下载 `orbat-agent-v0.3.6-dsh-plugin.zip` 并解压。
2. 在 DSH Desktop 打开 **Plugin Manager → Install bundle**，选择解压目录。
3. 新建会话，确认三个 ORBAT 工具与 **设置 → 编制图** 页面出现。
4. 先用小 JSON 验证，再出图并 `present` PNG。

插件默认把产物写到当前会话工作区的 `编制插件产物仓库`；可在设置中指定绝对目录。首次出图若没有 Node 24+，插件会下载固定版本 Node 并校验 SHA-256。

## 已知问题

- Android APK 为 debug 签名，仅用于公开测试，不能上架应用商店。
- Windows 安装器与主程序未做代码签名，可能出现 SmartScreen 提示。
- 渲染布局最右列的超长标签可能贴边裁切（线上渲染器限制）。
- 插件出图依赖 `spatialillusions.com`。

## 开源

MIT License · 署名 LStR-40。详见 [LICENSE](LICENSE)。
