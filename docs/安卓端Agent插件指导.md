# 安卓端 Agent 插件指导 v2.2 —— 把「编制生成器」当外挂插件用

> 写给手机本机运行的外部 Agent。你负责读资料、形成编制描述、生成编制 JSON；
> 「编制生成器」App（com.orbat.orbat_core）负责本地校验 + 出图（PNG/SVG）。
> v2.2 修订：触发方式以「打开 App 即自动处理」为主；commandLevels 规范；
> 位号统一 0 基；单实例说明。

---

## 〇、勘误与修订记录（以本版为准）

1. **JSON 结构**：`options{...}` + `subOrganizations[]` + 根节点 `commandLevels`。
   `name/sidc/children` **不被解析**。
2. **"7 键"** 指 `options` 里的 7 个键（见二节），不是节点总数。
3. **SIDC"14 位全 0"** 指 0-based 第 16~29 位（修饰 6 + 保留 8）；
   **梯队（0-based 8~9 位）本来就可以非零**。
4. **注释上限 ≤12 汉字 / ≤20 字母**（agent_prompts.txt 旧版写的 24 已修正）。
5. **commandLevels 会被 App 改写**：见二节规范（优先 3、过宽可 2、禁 1/4）。
6. **触发**：打开 App 即自动处理交接目录（见三节），intent 只是备用。
7. **单实例**：App 全局只有一个实例，再次点图标回到已打开的界面。

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
  "commandLevels": "3",
  "subOrganizations": [
    { "options": { "sidc": "...", "uniqueDesignation": "第1合成营", "additionalInformation": "" },
      "subOrganizations": [] }
  ]
}
```

- `options` 三键必填：`sidc`（30 位）、`uniqueDesignation`（称号）、`additionalInformation`（注释，可为空串）
- 其余键（dashed/outline/plain-text-mode/showMapLabels）App 会自动补全，**你不需要写**
- **不要用** `name` / `sidc` 顶层键、`children`——都不被解析

### commandLevels 规范

- **优先写 `"3"`**；预计出图过宽可改 `"2"`；**禁用 `"1"` 和 `"4"`**
- App 尊重你写的 `"2"`；写了 `"1"`/`"4"` 或没写 → 归一化时强制为 `"3"`
- 只出现在根节点，子节点不带
- 注意 App 归一化后写回的是**最终生效值**——你写 `"3"` 归一化后仍是 `"3"`，
  你写 `"2"` 归一化后是 `"2"`；想确认生效值看 `<名>.normalized.json`

### SIDC 位段（**0-based 索引**，与 `agent_prompts.txt`/码表一致）

| 0-based 位 | 含义 | 取值 |
|---|---|---|
| 0-1 | 版本 | 必须 `13` |
| 2-3 | 上下文 | 必须 `03` |
| 4-5 | 符号集 | `10` 陆地 / `01` 空中 |
| 6-7 | 状态 | 必须 `00` |
| **8-9** | **梯队** | **可非零**：`11`组 `12`班 `13`小队 `14`排 `15`连 `16`营 `17`团/群 `18`旅 `21`师 `22`军 `23`集团军 `24`方面军 `25`军区 `26`总指挥部，`00`=未指定；`19/20` 禁用 |
| **10-15** | **主实体 6 位** | 须在符号集标准表内（全表见 orbat_docs/SIDC权威对照表.md）；`000000`=通用 |
| 16-21 | 修饰（类型2+机动2+扇区2） | 应 `000000`（非零仅 warn；载具/口径细节写进称号） |
| 22-29 | 保留 | 必须 `00000000`（非零 = 红牌） |

示例 `130310001512110000000000000000`：版本13 / 上下文03 / 陆地10 / 状态00 / **梯队15（连）** / **主实体121100（步兵）** / 修饰000000 / 保留00000000。
你此前观察到的"15 位上的 01/02/04/05"是主实体码组成部分（步兵系细分），**合法**。

其他硬规则（红牌）：`uniqueDesignation` 不能含「空格+左括号」；注释 ≤12 汉字 / ≤20 字母，
不含空格+括号、指挥官姓名；兄弟称号不重复；`110000`(HQ) 加类型修饰 `98` 被拦。

## 三、触发方式

**方式 A：打开 App 即自动处理（主路径，推荐）**
- 只要交接目录 `orbat_inbox/` 里有待处理 JSON，**打开 App 约 2 秒后自动开始跑批**，无需任何点击
- 你用 `open`（启动器方式）打开即可
- 处理过程弹全屏渲染页（每个文件 15~60 秒，简单树通常更快），**期间不要把 App 切到后台**

**方式 B：intent 触发（备用）**
```bash
am start -a com.orbat.orbat_core.plugin.RUN
```

**方式 C：UI 触发（备用）**
App 顶栏 `⋮更多` → 「插件处理 · Agent 交接」。读屏/无障碍操作不算"离开应用"。

**单实例**：App 全局只有一个运行实例；App 已在运行时再点图标只是回到已打开界面，不会多开。

## 四、完成判定（轮询 `_status.json`）

```json
{"state":"running","total":2,"done":1,"current":"test3"}
{"state":"idle","lastRun":{"total":2,"validated":2,"rendered":2,"finishedAt":"..."}}
```
- 5~10 秒轮询一次；`state=idle` 即完成
- 每个文件明细看 `orbat_outbox/<名>.report.json`

## 五、报告明细（`<名>.report.json`）

```json
{
  "file": "test3", "ok": true, "nodeCount": 14, "depth": 3,
  "red": [], "warn": [ ... ],
  "render": {"ok": true, "png": "...orbat_outbox/test3.png", "svg": "...test3.svg"}
}
```
- `ok=true` 且 `render.ok=true` → 完成
- `render.ok=false` 且 error 含「被取消」→ 处理中 App 被切走，重放该 JSON 再触发
- 只有 `error` 字段（无 red/render）→ JSON 结构无法解析，对照第二节检查

## 六、交接细节

| 事项 | 约定 |
|---|---|
| 文件名 | 中文可；建议不含空格/引号/斜杠；产物沿用同名主干 |
| 子目录 | 不扫描——只处理 `orbat_inbox/` 根一级的 `.json` |
| 写入原子性 | 先写 `<名>.json.tmp` 再 rename 成 `.json`，避免 App 扫到半截文件 |
| **同名覆盖** | inbox→done 与 outbox 产物同名都会**静默覆盖**——换批次务必换文件名 |
| 源文件去向 | 处理完自动移入 `orbat_inbox/done/` |
| 批量 | inbox 里所有 `.json` 按文件名顺序逐个处理 |

## 七、产物交付

产物**留在 `orbat_outbox/`**（权威位置）。需要放进 `DSH-Go/` 等其他目录时由你自行复制，App 不搬运。

## 八、码表与提示词

- `orbat_docs/SIDC权威对照表.md` —— 陆上 214 / 空中 53 实体码 + 梯队 15 档，全量语义（0-based 位号）
- `orbat_docs/agent_prompts.txt` —— 完整 SIDC 规范提示词（注释上限已修正为 12）+ 识图三段式工作流
- App 内「⋮更多 → 导出 Agent 提示词」可随时重新导出

## 九、能力边界

- 你承担资料读取与 JSON 生成；App 只做校验 + 出图
- 出图依赖网络（spatialillusions.com）
- 首次使用需人工授权一次「所有文件访问」（App 内引导）
