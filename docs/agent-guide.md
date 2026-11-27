# Agent 读取与工作指引

本指南给接手项目的 Agent/协作者使用。目标：**用最少上下文找到正确入口，按 Spec Kit 流程改动，不破坏单一信源与发布快照。**

## 1. 最短路径

```text
AGENTS.md
  → README.md
  → specs/000-system-baseline/spec.md
  → specs/000-system-baseline/plan.md
  → 任务对应的 spec（001/002/003）
  → 只读相关源码模块
```

不要一开始递归读取整个仓库：`版本/`、`发布物料/`、`归档/` 很大且不是编辑源。

## 2. 按任务路由

### 修 bug

1. 读 `specs/000-system-baseline/spec.md` 与相关模块。
2. 读 `app/docs/踩坑与设计决策.md`，确认是否已踩过。
3. 先写复现/测试，再改代码；改动只在 `app/lib`。
4. 跑 `engine_selfcheck`、相关 selfcheck；涉及渲染跑 E2E。
5. 需要新规格时建 `specs/NNN-*/`，不要把修复只写在聊天里。

### 新功能/优化

1. 读 `.specify/memory/constitution.md`。
2. 建 `specs/NNN-name/spec.md`：用户故事、FR、成功标准、非目标。
3. `plan.md`：技术方案、Constitution Check、风险。
4. `tasks.md`：可独立验收的任务。
5. 实现后更新 tasks/checklist，跑验证；`converge` 检查遗漏。

### 发布

1. 版本号：`app/pubspec.yaml` + `app/lib/core/version.dart` 同步。
2. Windows Release 在 ASCII 路径构建；CLI 用 `app/scripts/build_cli.sh`。
3. 隐私扫描；生成 `SHA256SUMS.txt`。
4. 产物放 `版本/vX.Y.Z/`；不要反向修改 `app/lib`。
5. GitHub Release 附件直传（历史流程见 `转交文件.md`，仅参考）。

### Android

1. 先读 `specs/003-android/spec.md`、`plan.md`（**规划中，未实现**）。
2. 现状：代码完整、模式三已验证；缺权限模型与正式签名。
3. 关键文件：
   - `app/android/app/src/main/AndroidManifest.xml`
   - `app/android/app/build.gradle.kts`
   - `app/android/app/src/main/kotlin/com/orbat/orbat_core/MainActivity.kt`
   - `app/lib/ui/render_webview_page.dart`
   - `app/lib/render/webview_renderer.dart`
   - `app/lib/services/plugin_bridge.dart`
4. 先确认分发渠道（ sideload / Play ）再决定 `MANAGE_EXTERNAL_STORAGE` 或 SAF/MediaStore。

### CLI / DSH 插件

1. CLI 协议：`dsh-orbat-plugin/CLI-PROTOCOL.md`
2. Agent 使用：`dsh-orbat-plugin/AGENT-GUIDE.md`
3. 单一信源：`app/docs/source-of-truth.md`
4. 插件测试：`cd dsh-orbat-plugin && node --test`
5. 日志：`orbat-cli.exe logs`（正常日志 14 天）、`logs --tail`、`logs --errors`；失败信封含 `errorReport` 路径。
6. Schema：`orbat-cli.exe schema --out orbat.schema.json`；`render --validate-only` 只校验不出图。

## 3. 源码地图

| 模块 | 关键文件 | 说明 |
|---|---|---|
| 启动/主题/全局异常 | `app/lib/main.dart` | S6 全局异常兜底 |
| 流水线 | `app/lib/pipeline.dart` | 识图→校验→修复→出图 |
| DeepSeek | `app/lib/ai/deepseek_client.dart` | S3 错误分级、S4 动态超时 |
| 领域模型 | `app/lib/core/orbat.dart` | ORBAT 树/校验 |
| SIDC | `app/lib/core/sidc_*.dart` | 码表、规则、审计 |
| 渲染 | `app/lib/render/renderer.dart` | Windows Node 渲染 + 原子写 |
| Android 渲染 | `app/lib/render/webview_renderer.dart` | WebView 线上渲染 |
| 插件桥 | `app/lib/services/plugin_bridge.dart` | Download 交接目录 |
| 设置/密钥 | `app/lib/services/settings_store.dart`、`core/secret_store.dart` | DPAPI/Keystore |
| CLI | `app/lib/cli/main.dart`、`app/cli_aot/` | AOT CLI |
| DSH 插件 | `dsh-orbat-plugin/index.js`、`lib/*` | 三工具 + 设置页 |

## 4. 单一信源

```text
app/lib/**                     唯一 Dart 源
app/cli_aot/lib/**             生成物，勿手改
app/cli_aot/stubs/secret_store.dart  CLI 覆盖
```

命令：

```powershell
cd app
dart tool/sync_cli_sources.dart --check --skills
dart tool/sync_cli_sources.dart
```

- `build_cli.sh` 构建前自动同步。
- pre-commit 钩子已安装；CI 见 `.github/workflows/single-source.yml`。
- 技能副本：根 `.agents/skills/orbat-json-writer` 为正本。

## 5. 常用验证

```powershell
cd app
C:\flutter\bin\flutter.bat pub get
C:\flutter\bin\dart.bat analyze lib
C:\flutter\bin\dart.bat run test\engine_selfcheck.dart
C:\flutter\bin\dart.bat run test\ai_selfcheck.dart
C:\flutter\bin\dart.bat run test\stability_selfcheck.dart
```

```bash
cd app
bash scripts/build_cli.sh /c/orbat-build-test/orbat-cli.exe
```

```powershell
cd dsh-orbat-plugin
node --test
```

## 6. 不要做的事

- 不要手改 `app/cli_aot/lib/**`、`版本/**`、`发布物料/**`。
- 不要把 API Key、真实姓名、本机路径写进仓库/日志/截图。
- 不要在每个对话默认加载大文档；只读任务相关 spec。
- 不要把“计划”写成“已完成”；未验证项保持 `[ ]`。
- 不要删除 `输出文件存档/` 里的用户产物。
- 不要在中文路径做 Windows Release 构建。

## 7. 清理与归档

- 一次性测试产物、探针脚本、旧包已移到 `归档/2026-11-27-清理/`。
- `app/build`、`.dart_tool`、`windows/flutter/ephemeral` 已删除；需要时重新生成。
- 新增临时文件请放 `归档/` 或 `app/test/fixtures/`，不要堆在根目录。
- 详见 `docs/cleanup-2026-11-27.md`。
