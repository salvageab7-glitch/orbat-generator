# 单一信源与副本规则

> 生效：2026-11-27（Spec Kit `002-single-source`）
> 适用范围：`app/lib` → `app/cli_aot/lib`，以及 `.agents/skills/orbat-json-writer` 的根/app 副本。

## 四类文件

| 类别 | 位置 | 规则 |
|---|---|---|
| **源** | `app/lib/**` | 唯一可编辑的 Dart 源 |
| **生成物** | `app/cli_aot/lib/**` | 由工具从 `app/lib` 生成，不手工编辑 |
| **CLI 专用** | `app/cli_aot/lib/env_probe.dart`、`app/cli_aot/stubs/secret_store.dart` | 保留，不参与源/生成比较；stub 会覆盖生成的 `core/secret_store.dart` |
| **发布快照** | `版本/**`、`发布物料/GitHub仓库导出/**` | 发布流程产物，不反向修改 `app/lib` |

GUI 的 `main.dart`、`ui/**` 不进入 CLI；CLI 入口是 `lib/cli/main.dart`。

## 命令

在 `app/` 下：

```powershell
# 只检查（不写文件）
C:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/sync_cli_sources.dart --check --skills

# 同步 CLI 源
C:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/sync_cli_sources.dart

# Windows 包装
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync_cli_sources.ps1 -Check -Skills
```

退出码：

- `0`：一致/同步成功；
- `1`：发现 `missing` / `extra` / `different` / `flutter-import` / 技能副本不一致；
- `2`：参数或路径错误。

## 生成集合

复制：

```text
core/
ai/
render/
services/
i18n/
pipeline.dart
cli/main.dart
```

覆盖：

```text
cli_aot/lib/core/secret_store.dart <- cli_aot/stubs/secret_store.dart
```

保留：

```text
cli_aot/lib/env_probe.dart
cli_aot/lib/stubs/
cli_aot/lib/.dart_tool/
cli_aot/lib/orbat-logs/
```

## 构建集成

`scripts/build_cli.sh` 第 1 步调用：

```bash
"$DART" run "$APP_DIR/tool/sync_cli_sources.dart"
```

随后仍保留 `grep -rq "package:flutter"` 双保险。

## 门禁

### 本地 pre-commit

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
```

设置 `core.hooksPath=.githooks`；每次提交前运行：

```bash
dart tool/sync_cli_sources.dart --check --skills
```

找不到 Dart 时跳过（不阻塞提交），但 CI 仍会检查。

### GitHub Actions

`.github/workflows/single-source.yml` 在 push/PR 时用 `dart-lang/setup-dart` 运行同一检查。工具只依赖 `dart:io`，不需要 Flutter/pub get。

## 技能副本

以项目根 `.agents/skills/orbat-json-writer` 为正本；`app/.agents/skills/orbat-json-writer` 由 `--skills` 校验。版本目录中的副本是发布快照，不参与日常同步。

## 故障处理

| 现象 | 处理 |
|---|---|
| `different` 指向某个 `core/*.dart` | 确认是否只改了生成物；运行同步覆盖，或把改动移回 `app/lib` |
| `extra` 指向 `cli_aot/lib` 新文件 | 若是 CLI 专用，加入工具保留清单/文档；否则删除 |
| `missing` | 运行同步 |
| `flutter-import` | 该文件不应进入 CLI；检查是否误把 GUI 文件加入 managed 集合 |
| 技能副本不一致 | 以根 `.agents` 为正本，同步 `app/.agents` 后重跑 |

## 不做的事

- 不自动生成 `版本/`、GitHub 导出（发布流程负责）。
- 不把 `app/cli_aot` 改为共享 package（后续独立 feature）。
- 不删除 `env_probe.dart`。
