# 安卓端 Agent 插件指导 v2 —— 把「编制生成器」当外挂插件用

> 写给手机本机运行的外部 Agent。你负责读资料、形成编制描述、生成编制 JSON；
> 「编制生成器」App（com.orbat.orbat_core）负责本地校验 + 出图（PNG/SVG）。
> 本版已按手机端 Agent 实测反馈修订：JSON 结构、SIDC 位段、触发方式、
> 完成判定、交接细节全部以 App 实际实现为准。

---

## 〇、先行勘误（v1 文档的错，以此版为准）

1. **JSON 结构**：正确结构是 `options{...}` + `subOrganizations[]` + 根节点 `commandLevels`。
   v1 写的 `name/sidc/children` **是错的**——App 不认 `children`，写了会解析失败。
2. **"7 键"** 指 `options` 里的 7 个键（见二节），不是节点总数。
3. **SIDC"14 位全 0"** 指主实体之后（1-based 第 17~30 位）；
   **梯队（9~10 位）本来就可以非零**，v1 没写位段表导致误读。

## 一、目录协议（固定）

```
/storage/emulated/0/Download/
├── orbat_inbox/          ← 你把编制 JSON 放这里（处理后移入 done/）
│   └── done/
├── orbat_outbox/         ← App 产物与报告（你从这里取）
│   └── _status.json      ← 批处理状态信号（轮询判定完成）
└── orbat_docs/           ← SIDC 权威对照表.md + agent_prompts.txt（已就位）
```

## 二、编制 JSON 规范（唯一正确结构）

```json
{
  "options": {
    "sidc": "130310001512110000000000000000",
    "uniqueDesignation": "第5合成师",
    "additionalInformation": "注释不超过12个汉字"
  },
  "commandLevels": "1",
  "subOrganizations": [
    { "options": { "sidc": "...", "uniqueDesignation": "第1合成营", "additionalInformation": "" },
      "subOrganizations": [] }
  ]
}
```

- `options` 三键必填：`sidc`（30 位）、`uniqueDesignation`（称号）、`additionalInformation`（注释，可为空串）
- `commandLevels` **只出现在根节点**（"1"=指挥层级缩进一级），子节点不带
- 其余键（dashed/outline/plain-text-mode/showMapLabels）App 会自动补全，**你不需要写**
- **不要用** `name` / `sidc` 顶层键、`children`——都不被解析

硬规则（红牌，必须修）：

| 规则 | 说明 |
|---|---|
| SIDC 必须 30 位纯数字 | 位数错 = 红 |
| 位 1-2 = `13` | 版本位 |
| 位 3-4 = `03` | 上下文 |
| 位 5-6 = `10`（陆地）或 `01`（空中） | 符号集 |
| 位 7-8 = `00` | 状态 |
| 位 9-10 = 梯队码 | **可非零**，取值见下表；`19/20` 禁用 |
| 位 23-30 = `00000000` | 保留位，非零 = 红 |
| `uniqueDesignation` 不能含「空格+左括号」 | 渲染器会卡死 |
| 注释 ≤12 汉字 / ≤20 字母，不含空格+括号、指挥官姓名 | 超长 = 红 |

**梯队码表（位 9-10）**：`11`组/车组 `12`班 `13`小队 `14`排 `15`连 `16`营 `17`团/群 `18`旅 `21`师 `22`军 `23`集团军 `24`方面军 `25`军区 `26`总指挥部，`00`=未指定。

**SIDC 位段示例**：`130310001512110000000000000000`
= 版本13 + 上下文03 + 陆地10 + 状态00 + **梯队15（连）** + **主实体121100（步兵）** + 修饰000000 + 保留00000000。
你观察到的"第 15 位 01/02/04/05"是主实体码的组成部分（步兵系细分），**合法**。

软规则（warn，不拦截但建议遵守）：
- 位 17-22（类型/机动/扇区修饰）应 `000000`——非零仍可出图，但新规范要求载具/口径细节写进称号
- 主实体 6 位须在符号集标准表中（全表见 `orbat_docs/SIDC权威对照表.md`）
- 兄弟节点称号不重复；根直属下属 ≤10；树深 ≤3；父子梯队不倒挂

## 三、触发方式（两种，任选）

**方式 A：intent 直接触发（推荐，免人工点界面）**
```bash
am start -a com.orbat.orbat_core.plugin.RUN
```
- App 未运行会自动拉起并开始处理；已运行则热触发
- 兼容：App 冷启动时收到的 intent 会在界面就绪后自动执行（约 1~2 秒延迟）
- 处理过程中 App 会弹全屏渲染页（每个文件 15~60 秒，联网渲染），
  **期间不要把 App 切到后台**——切走会中断当前文件（报告记"出图被取消"，产物可能已写出但不可靠，建议重跑该文件）

**方式 B：UI 触发（备用）**
打开 App → 顶栏 `⋮更多` → 「插件处理 · Agent 交接」。
读屏/无障碍操作不算"离开应用"；只要 App 保持前台即可。

## 四、完成判定（轮询 `_status.json`）

处理开始后 App 会在 `orbat_outbox/_status.json` 写状态：
```json
{"state":"running","total":2,"done":1,"current":"test3"}
{"state":"idle","lastRun":{"total":2,"validated":2,"rendered":2,"finishedAt":"..."}}
```
- 建议 5~10 秒轮询一次；`state=idle` 即完成
- `validated` = 红牌 0 的文件数；`rendered` = 出图成功数
- 每个文件的明细看 `orbat_outbox/<名>.report.json`（第五节）

## 五、报告明细（`<名>.report.json`）

```json
{
  "file": "test2", "ok": true, "nodeCount": 25, "depth": 4,
  "red": [], "warn": [ ... ],
  "render": {"ok": true, "png": "...orbat_outbox/test2.png", "svg": "...test2.svg"}
}
```
- `ok=true` 且 `render.ok=true` → 完成
- `render.ok=false` 且 error 含「被取消」→ 处理中 App 被切走，重放该 JSON 再触发即可
- 只有 `error` 字段（无 red/render）→ JSON 结构无法解析，对照第二节检查

## 六、交接细节

| 事项 | 约定 |
|---|---|
| 文件名 | 中文可；建议不含空格/引号/斜杠；产物沿用同名主干 |
| 子目录 | 不扫描——只处理 `orbat_inbox/` 根一级的 `.json` |
| 写入原子性 | 先写 `<名>.json.tmp` 再 rename 成 `.json`，避免 App 扫到半截文件 |
| 同名覆盖 | outbox 同名产物直接覆盖；需要区分批次就换文件名（如 `xxx_v2.json`） |
| 源文件去向 | 处理完自动移入 `orbat_inbox/done/` |
| 批量 | inbox 里所有 `.json` 按文件名顺序逐个处理，一个 intent 全跑完 |

## 七、产物交付

产物**留在 `orbat_outbox/`**（权威位置）。需要放进 `DSH-Go/` 等其他目录时由你自行复制，App 不搬运。

## 八、码表与提示词（已就位）

- `orbat_docs/SIDC权威对照表.md` —— 陆上 214 / 空中 53 实体码 + 梯队 15 档，全量语义
- `orbat_docs/agent_prompts.txt` —— 完整 SIDC 规范提示词（交给你的模型）+ 识图三段式工作流
- App 内「⋮更多 → 导出 Agent 提示词」可随时重新导出

## 九、能力边界

- 你承担资料读取与 JSON 生成；App 只做校验 + 出图
- 出图依赖网络（spatialillusions.com）
- 首次使用需人工授权一次「所有文件访问」（App 内引导）
