# Agent Contract（单一规则源）

> 本目录是面向 Agent 的规格契约。`prompt.dart`、`.agents/skills/orbat-json-writer`、`AGENT-GUIDE.md` 必须引用本目录，不再各自复制一套规则。

## 1. SIDC 30 位（0-based）

| 位（0-based） | 长度 | 含义 | 项目规则 |
|---|---|---|---|
| 0–3 | 4 | 版本/上下文 | 固定 `1303` |
| 4–5 | 2 | 符号集 | `10` 陆地；`01` 空中 |
| 6–7 | 2 | 状态 | `00` |
| 8–9 | 2 | 梯队 | 见 `hq-echelon-table.md` |
| 10–15 | 6 | 主实体 | 按符号集查全量表 |
| 16–17 | 2 | 类型修饰 | 默认 `00` |
| 18–19 | 2 | 机动修饰 | 默认 `00` |
| 20–21 | 2 | 扇区修饰 | 默认 `00` |
| 22–29 | 8 | 保留 | `00000000` |

> 旧文档里的“第 9-10 位/第 11-16 位”是 1-based；本契约统一用 **0-based**。写文档时必须标注基准，禁止混用。

## 2. 注释

- `additionalInformation` 上限：**12 个汉字 / 20 个拉丁字母**。
- 只写单位职能短名或驻地；驻地放不下时写进名称或省略，**不新增 location 字段**（2026-11-27 决策）。
- 禁止写指挥官姓名、分析/置信度/自检说明、长装备清单。

## 3. 修饰位实际行为

| 情况 | validate 行为 |
|---|---|
| 位 16–29 任一修饰/保留位非 0 | **warn**，不阻断；历史 JSON 仍可出图 |
| `110000` + 类型修饰 `98` | **red**，阻断 |
| SIDC 长度≠30、符号集非法、主实体未知 | **red**，阻断 |
| 注释超长、空格+括号、同父重名 | **red/warn** 按 `schema_rules.dart`/`orbat.dart` 实际实现 |

> 项目规范仍要求“主实体后 14 位全 0”；但校验器当前只给 warn。是否为历史 JSON 升级为红牌，待产品决策。

## 4. commandLevels

- 仅在根节点；子节点禁止出现。
- 设置页“指挥层级 commandLevels”可选 **3（默认，推荐）** 或 **2**；该设置会覆盖 JSON 根节点，report 用 `commandLevelsSource:"settings"` 标明。
- 归一化规则：输入 `"2"` 保留；`"1"`/`"4"`/空/其他 → `"3"`。
- report 必须记录 `commandLevelsInput` 与 `commandLevelsOutput`，避免“输入 1 输出 3”的误解。
- 大图策略（2026-11-27 决策）：可降级为 `"2"`，但输出必须是**整图**，不采用分页。

## 5. 命名/HQ

- 同父禁止同名或名称互为前缀。
- 名称禁止“空格 + 左括号”；用紧贴括号或 `·`。
- HQ 用码见 [`hq-echelon-table.md`](hq-echelon-table.md)。

## 5.1 JSON Schema（结构校验）

- 文件：`schema/orbat.schema.json`；CLI：`orbat-cli.exe schema --out orbat.schema.json`。
- 约束：根/节点形状、根节点独有 `commandLevels`、`options` 只允许 7 键、`sidc` 为 30 位数字。
- Schema 只管结构；注释长度、SIDC 语义、重名等仍以 `validate` 为准。

## 6. 提示词版本

`agent_prompts.txt` 头部必须包含：

```text
# PROMPT_VERSION: 2026-11-27-p1
# COMMENT_LIMIT: 12 CJK / 20 letters
# SIDC_BASE: 0-based
```

旧文件（如 24 字版本）在 App 启动/导出时应被覆盖；以本目录为准。

## 7. 模式三状态/产物

- `_status.json`：`runId/state/triggerAt/current/files[]`。
- 产物：`<base>__<runId>.png|svg|normalized.json|report.json`。
- `deliverable=true` 才表示可交付；红牌/质量失败为 false。
- 失败/渲染未交付时，`_status.json` 提供 `log/logTail`，并写 `outbox/<runId>.log.txt`。
- 详见 `dsh-orbat-plugin/README.md` 的 Android trigger/status 段。

## 8. 维护

- 修改规则：先改本目录 → 再同步 `prompt.dart` / skill / AGENT-GUIDE。
- 任何 Agent 文档出现 12/24、0/1 基、硬/软 矛盾时，以本目录为准。
