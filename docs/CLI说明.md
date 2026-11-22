# ORBAT CLI — 外部 Agent 调用说明（v0.3.6）

`orbat-cli.exe` 是编制生成器的命令行入口，适合外部 Agent、批处理和自动化脚本调用。Windows 安装包已内置该 exe；源码构建方式见根 README。

## 位置

```
编制生成器v0.3.6\
├── orbat-cli.exe   ← 独立 exe，不需要 Dart SDK
├── runtime\        ← 渲染脚本（render_orbat.js + cdp.js），出图必需
└── data\           ← GUI 资源
```

## 前置条件

| 依赖 | 哪些命令需要 | 说明 |
|---|---|---|
| `runtime\` 与 exe 同目录 | render / batch / generate | 安装包已带 |
| Node.js ≥ 24 | render / batch | 完整版内置；精简版需自装 |
| Chrome 或 Edge | render / batch | Windows 一般有 Edge |
| 网络（api.deepseek.com） | generate / batch | 模式一/二需要 |
| 网络（spatialillusions.com） | render / batch | 出图需要 |
| DeepSeek API Key | generate / batch | 模式三不需要 |

本地命令 `parse` / `validate` / `normalize` / `audit` / `edit` / `usage` / `config` / `retry-tile` 不需要 Node、浏览器或网络。

## 调用约定

- **stdout**：只有一个 JSON 对象，可直接解析。
- **stderr**：诊断、进度、日志，不污染 stdout。
- **退出码**：`0` 成功；`1` 执行失败；`2` 参数错误；`3` 校验/自检/批量发现问题（`audit --strict` 也算）。

成功信封：

```json
{"ok": true, "command": "validate", "data": {"nodeCount": 44, "redCount": 0, "warnCount": 0, "issues": []}}
```

失败信封：

```json
{"ok": false, "command": "render", "error": "渲染失败：..."}
```

## 输入优先级

`parse` / `validate` / `normalize` / `audit` / `edit`：

1. `--in <文件>`
2. 位置文件参数
3. stdin

`render` / `generate` 还支持 `--image`、`--text`。`--in` 读取时会自动去掉 UTF-8 BOM。

## 常用命令

```bash
# 版本
orbat-cli.exe --version

# 校验（红牌 exit 3）
orbat-cli.exe validate --in 编制.json

# 归一化；顺带修正 HQ 梯队码并返回修正数量
orbat-cli.exe normalize --in 编制.json --adapt-for-render

# 出图
orbat-cli.exe render --in 编制.json --out 编制图

# 就地改名（stdin 输入，无 --out 时把结果 JSON 输出到 stdout）
type 编制.json | orbat-cli.exe edit --path "师部及师部营" --note "师部" --out 编制.json

# 审计；strict 模式下红牌 exit 3
orbat-cli.exe audit --strict --in 编制.json
```

## 命令一览

| 命令 | 用途 |
|---|---|
| `parse` | 解析 JSON，返回节点数、层级、根名 |
| `validate` | 规则校验，返回红牌/警告清单 |
| `audit` | SIDC 与名称一致性审计；默认只读建议，`--strict` 红牌 exit 3 |
| `edit` | 按 `--path` 修改名称/注释/SIDC |
| `normalize` | 归一化为渲染器 7 键结构 |
| `render` | 出 PNG + SVG |
| `generate` | AI 识图/文字生成编制（需要 API Key） |
| `batch` | 批量识图 + 校验 + 出图 |
| `retry-tile` | 对单块重试识图 |
| `selfcheck` | 环境/引擎自检；`--smoke` 真渲染 |
| `usage` | 调用统计 |
| `config` | 查看版本、模型、配置路径 |
| `tutorial` | 导出内置教程 |
| `prompts` | 导出识图提示词 |

完整选项见 `orbat-cli.exe --help`，协议字段见仓库 `dsh-orbat-plugin/CLI-PROTOCOL.md`。

## 其他入口

- 模式三（外部 Agent 识图）快速开始：`docs/MODE3-AGENT-QUICKSTART.zh.md`
- DSH Desktop 插件：`dsh-orbat-plugin/README.md`
