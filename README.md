# 编制生成器 / ORBAT Generator

把编制结构图或文字资料转成结构化 ORBAT JSON（30 位 SIDC），再调用线上渲染器输出 PNG/SVG。支持 Windows、Android，并附带 DSH Desktop Agent 插件。

当前版本：**0.3.7-beta 公开测试版**。

## 功能概览

- 识图 / 文字 → ORBAT JSON（OpenAI 兼容 API；DeepSeek / OpenCode Go 等）
- 本地规则引擎生成/校正 30 位 SIDC，名称—码一致性审计
- 红牌校验 + 补丁式修复（不重写整棵树）
- 调用线上渲染器出 PNG/SVG
- 树视图就地编辑名称、注释、编码
- 中英双语界面与教程
- 模式三：外部 Agent 识图/出图，无需软件 API Key
- CLI（`orbat-cli.exe`）供外部 Agent 调用
- DSH Desktop 插件：`orbat_validate_json` / `orbat_render_json` / `orbat_workflow_self_check`

## 0.3.7-beta 重点改动

- 模式三 P0/P1/P2：自动扫描、runId 状态、deliverable、PNG 质量、时间戳产物、红牌阻断、日志诊断
- `validate-only`、JSON Schema、码表缺口、大图整图布局、批量重扫/去重
- CLI 正常日志 14 天 + 独立错误报告；新增 `logs` 命令
- 设置页“服务类型”：DeepSeek / OpenAI 兼容（含 OpenCode Go）
- “读取模型列表”，OpenCode Go 自动标记 vision
- OpenCode Go：`x-opencode-session` + `thinking:disabled`
- `commandLevels` 2/3（默认 3）
- 设置页底部显示版本号

## 下载

请到 [Releases](https://github.com/salvageab7-glitch/orbat-generator/releases/tag/v0.3.7-beta) 下载：

| 附件 | 说明 |
|---|---|
| `orbat-generator-v0.3.7-beta-full-setup.exe` | Windows 完整版安装器（内置 Node.js，自动检测 VC++） |
| `orbat-generator-v0.3.7-beta-lite-setup.exe` | Windows 精简版安装器（需自备 Node.js ≥24） |
| `orbat-agent-v0.3.7-beta-dsh-plugin.zip` | DSH Desktop 插件包，解压后 Plugin Manager 安装 |
| `orbat-agent-v0.3.7-beta-dsh-plugin.tgz` | DSH 插件 npm 包形式 |
| `orbat-generator-v0.3.7-beta-android-debug.apk` | Android 侧载测试包（debug 签名） |
| `SHA256SUMS.txt` | 附件 SHA-256 校验值 |

## 目录结构

```text
lib/                 # Flutter / 纯 Dart 源码
  core/              # 规则引擎、SIDC、数据模型、校验、自动修复
  ai/                # 提示词、OpenAI 兼容客户端、模型列表
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

## 开发

```powershell
cd app
C:\flutter\bin\flutter.bat pub get
C:\flutter\bin\flutter.bat run -d windows
```

CLI：

```bash
cd app
bash scripts/build_cli.sh /c/orbat-build-test/orbat-cli.exe
```

测试：

```powershell
cd app
C:\flutter\bin\dart.bat run test\engine_selfcheck.dart
C:\flutter\bin\dart.bat run test\stability_selfcheck.dart
C:\flutter\bin\dart.bat run test\schema_selfcheck.dart
```

## 环境

- Windows 10/11 64 位；Android 7.0+
- Edge / Chrome
- Node.js ≥ 24（插件会自动准备固定版本）
- 模式一/二识图需要 OpenAI 兼容 API Key；模式三不需要软件 API

## 已知问题

- Android 使用 debug 签名，仅用于公开测试。
- 渲染依赖 `spatialillusions.com`，站点不可用时无法出图。
- 普通 OpenAI 兼容服务的 `/models` 能力元数据不统一。

## 开源

MIT License · 署名 LStR-40
