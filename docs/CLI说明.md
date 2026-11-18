# ORBAT CLI — 外部 Agent 调用说明（v0.2 · 独立 exe 版）

## 位置与两种入口

```
编制生成器v0.2\
├── orbat-cli.exe   ← 【推荐】独立 exe，不需要 Dart SDK
├── orbat.bat       ← 备用：走 dart run，需本机装 Dart（开发/调试用）
├── cli\            ← orbat.bat 用的 Dart 源码
├── runtime\        ← 渲染脚本（render_orbat.js + cdp.js），出图必需
└── data\           ← GUI 资源
```

**给外部 Agent 用 `orbat-cli.exe`**。它是 AOT 编译的原生程序（约 9MB），
启动快、不弹窗、不依赖 Dart SDK。二者命令完全相同。

## 前置条件（重要：分发给别人时）

`orbat-cli.exe` 本身不依赖 Dart，但**出图**（`render` / `batch` / `generate --render`）依赖外部环境：

| 依赖 | 哪些命令需要 | 普通 Windows 用户是否自带 |
|---|---|---|
| `runtime\` 目录随 exe 同放 | render / batch / generate | 需随包分发（已在交付目录里） |
| Node.js ≥ 24 | render / batch | ❌ 通常没有，需安装 |
| Chrome 或 Edge 浏览器 | render / batch | ✅ 一般有 Edge |
| 网络（api.deepseek.com） | generate / batch | ✅ 一般有 |
| 网络（spatialillusions.com） | render / batch | ✅ 一般有 |
| API Key | generate / batch | ❌ 需申请，见下 |

只用 `parse` / `validate` / `normalize` / `usage` / `config` / `retry-tile` 这些
**本地命令时，不需要 Node.js、浏览器和网络**，纯粹离线可用。

## API Key 的配置（两种方式）

**方式一：环境变量（推荐给 Agent / 分发场景）**

```bash
set DEEPSEEK_API_KEY=sk-你的key
orbat-cli.exe generate --image 图.png --out 编制.json
```

环境变量优先级高于配置文件，且无需在本机写文件（适合共享机器）。

**方式二：配置文件**

`%APPDATA%\OrbatGenerator\config.json` 里填 `apiKey` 字段（GUI 设置里填）。
两种入口共用同一份配置。

## 调用约定

- **stdout**：只有一个 JSON 对象，可直接 `json.loads`
- **stderr**：诊断、进度、日志，不污染解析
- **exit code**：`0` 成功 / `1` 执行失败 / `2` 参数错误 / `3` 校验或自检发现问题

返回信封：

```json
{"ok": true, "command": "命令名", "data": { ... }}
{"ok": false, "command": "命令名", "error": "错误信息"}
```

## 命令一览

| 命令 | 用途 | 输入 |
|---|---|---|
| `parse` | 解析编制 JSON，返回节点数/层级/根名 | 文件或 stdin |
| `validate` | 校验，返回所有问题（红牌 exit=3） | 文件或 stdin |
| `normalize` | 归一化为渲染器 7 键结构 | 文件或 stdin |
| `render` | 出图（PNG+SVG） | JSON/图片/文本 |
| `generate` | AI 识图 / 文字生成编制 | 图片或 `--text` |
| `batch` | 批量识图+出图整个目录 | `--dir` 目录 |
| `retry-tile` | 单独重跑识别失败的图块 | 图片+网格坐标 |
| `selfcheck` | 环境自检（8 项） | 无 |
| `usage` | API 调用次数/token 统计 | 无 |
| `config` | 查看当前配置（key 只显示指纹） | 无 |

## 常用示例

```bash
# 解析（文件参数）
orbat-cli.exe parse 编制.json

# 校验（stdin 管道，Agent 常用）
cat 编制.json | orbat-cli.exe validate

# 识图生成
set DEEPSEEK_API_KEY=sk-xxx
orbat-cli.exe generate --image 图.png --out 编制.json

# 出图（透明底）
orbat-cli.exe render --in 编制.json --out 成品名 --no-white-bg

# 批量（整个目录）
orbat-cli.exe batch --dir 图片目录 --out-dir 输出目录 --recursive

# 重跑某个失败图块
orbat-cli.exe retry-tile --image 图.png --row 0 --col 1 --rows 1 --cols 4 --out 块.json

# 导出工作流提示词（模式三 Agent 用）
orbat-cli.exe prompts --type tile --out 提示词.txt

# 出图省略 --out → 自动用输入文件所在目录，返回值里宣告 outputDir
orbat-cli.exe render --in 编制.json

# 自检
orbat-cli.exe selfcheck
```

## 选项参考

| 选项 | 适用命令 | 说明 |
|---|---|---|
| `--in <文件>` | render | 输入 JSON |
| `--image <文件>` | generate / retry-tile | 输入图片 |
| `--text <内容或文件>` | generate | 纯文本输入 |
| `--out <路径>` | generate / retry-tile | 输出 JSON |
| `--out-dir <目录>` | batch | 批量输出目录（自动创建） |
| `--dir <目录>` | batch | 输入图片目录 |
| `--recursive` | batch | 递归子目录 |
| `--no-white-bg` | render / batch | 透明底 PNG |
| `--row/--col/--rows/--cols` | retry-tile | 失败块网格坐标 |
| `--command-levels 2\|3` | normalize | 渲染层级（默认 3） |

## 重新编译独立 exe（开发者）

当 `app/lib/` 下的 CLI 相关源码改动后，重建 exe：

```bash
cd app
bash scripts/build_cli.sh            # 默认输出到 编制生成器v0.2/orbat-cli.exe
bash scripts/build_cli.sh <自定义路径>
```

脚本会：同步 `lib/` → `cli_aot/`（纯 Dart 子项目）→ AOT 编译 → 冒烟验证。

**关键坑**：Dart AOT 编译会在 TEMP 下生成 `program.dill`，本机安全软件会删除系统 TEMP
里的 `.dill`，且 Dart 对中文路径敏感。脚本把 TEMP 重定向到纯 ASCII 路径
（可用 `ORBAT_BUILD_TMP` 环境变量覆盖）。这是编译能成功的唯一条件。
