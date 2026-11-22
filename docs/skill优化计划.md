# orbat-json-writer skill 优化分步计划（只读分析，尚未实施）

> 生成日期：2026-11-19　状态：**计划稿，未修改任何 skill 文件**
> 范围：仅 `orbat-json-writer`（用户指定）；其余 3 个 skill（github-publish / wincu-desktop-automation / workbuddy-dispatch）本次不优化。
> 副本策略：维持 3 份物理副本手工同步（项目根 `.agents/`、源码 `app/.agents/`、`版本/v0.3.5-beta/.agents/`），每步改完必须做 MD5 一致性校验。

---

## 一、现状盘点

### 1.1 与编制生成器相关的 4 个 skill（本次只改第 1 个）

| skill | 位置 | 规模 | 职责 | 本次 |
|---|---|---|---|---|
| **orbat-json-writer** | 项目 `.agents/skills/`（+2 副本） | 9 文件 / 1146 行 | 编制图 JSON 转写、SIDC 码表、出图工作流 | ✅ 优化对象 |
| github-publish | 用户级 `~/.workbuddy/skills/` | 5 文件 / 410 行 | GitHub 发布/隐私扫描/Release 观察 | 不动（含项目专用约定，职责独立） |
| wincu-desktop-automation | 项目 `.agents/skills/` | 1 文件 / 144 行 | Windows 桌面 GUI 自动化（wincu 插件） | 不动（通用工具，非编制专用） |
| workbuddy-dispatch | 项目 `.agents/skills/` | 1 文件 / 171 行 | 任务分包给 WorkBuddy GUI、验收记账 | 不动（通用工具，非编制专用） |

### 1.2 orbat-json-writer 文件结构与职责

| 文件 | 行数 | 职责 | 健康度 |
|---|---|---|---|
| `SKILL.md` | 326 | 主骨架：工作流、30位公式、常用码表、铁律、自检清单 | ⚠️ 过大，塞了太多 reference 内容 |
| `reference/sidc-codes.md` | 191 | 全量码表 + 历史修饰表 | ⚠️ 修饰表已废弃但仍占大篇幅 |
| `reference/us-bct.md` | 121 | 美军 BCT 历史约定 | ⚠️ 历史 modifier 记录密集 |
| `reference/us-bct-templates.md` | 83 | 美军营→班展开模板 | ⚠️ 30+ 处历史修饰码 |
| `reference/checklists.md` | 84 | QA 扫描规则 + 改树脚本模板 | ⚠️ 引用不存在的 sidc-check.py |
| `reference/examples.md` | 158 | 完整 JSON 示例 | ✅ 已归零修饰，较健康 |
| `reference/soviet-warsaw.md` | 73 | 苏军华约历史约定 | ⚠️ 历史码值 + 旧工具引用 |
| `reference/legacy.md` | 65 | 旧经验沿革 | ⚠️ 旧工具引用集中 |
| `reference/workflows.md` | 45 | 输入源→JSON 三条路 | ✅ 较健康 |

---

## 二、发现的问题（按严重度排序）

### 🔴 P0 — 指令"幽灵工具"：skill 引用了 5 个当前项目不存在的工具
skill 在多处命令外部 Agent 执行：
- `_tools\sidc.js`（find/meta/render）
- `_tools\sidc-check.py`
- `_tools\orbat.js`
- `_tools\render_orbat.js`（**实际存在于 `app/runtime/render_orbat.js`，路径写错**）
- `_qq_bridge\watcher\check_annotations.py`

**实测：这 5 个 `_tools/*` 路径在项目中全部不存在**。当前真实工具链是：
- `orbat-cli.exe`（校验 validate / 审计 audit / 出图 render / 提示词 prompts / 自检 selfcheck）
- `app/runtime/render_orbat.js`（出图脚本，由 CLI 内部调用）

**后果**：外部 Agent 严格按 skill 操作会去调不存在的命令，直接失败。这是最该先修的。

### 🔴 P0 — 注释长度口径冲突（skill 24 汉字 vs 软件 12 汉字）
- skill 主文件（`SKILL.md` 142/267/302/319 行）与 `checklists.md`：注释上限 **≤24 汉字**
- 软件现行规则 `app/lib/core/schema_rules.dart`：`kNoteMaxCjk=12`、`kNoteMaxLetters=20`（2026-11-18 用户新规）
- **schema_rules.dart 顶部注释自己就写着**："提示词说 12 字、校验器按 24 字放行"是要避免的自相矛盾——结果这个矛盾现在正存在于 skill 里。

**后果**：外部 Agent 按 skill 写 24 字注释，软件校验器判超限。

### 🟠 P1 — 同一规则散落多处，重复严重
量化结果（"行含关键词"计数）：

| 主题 | 出现文件数 | 典型位置 |
|---|---|---|
| 出图/线上版硬规则 | 5 文件（SKILL 18 次"出图"） | SKILL/checklists/legacy/soviet/workflows |
| 修饰位禁用（2026-11-19 新规） | 6 文件 | SKILL/sidc-codes/examples/us-bct/soviet/legacy |
| 梯队码表 | 5 文件 | SKILL/sidc-codes/checklists/us-bct/soviet |
| 编号单位逐个列 / ×N | 2 文件 | SKILL/workflows |
| commandLevels | 3 文件 | SKILL/checklists/examples |

**后果**：改一处规则要同步多处；本次改"修饰位禁用"就已改了 6 个文件，任一漏改即产生矛盾。

### 🟠 P1 — 历史数据约定与新规范混在正文，易误读
- `us-bct.md` / `us-bct-templates.md` / `soviet-warsaw.md` 正文里有 30+ 处历史修饰码（`0401`/`0601`/类型 `56`），虽然顶部已加"仅维护老文件参考"声明，但正文举例仍是带修饰的码。
- 外部 Agent 读到这些具体 SIDC 时，容易当成可照抄的模板。

### 🟡 P2 — 主文件 SKILL.md 过重（326 行）
既写工作流、又写码表、又写铁律、又写出图细节，reference 的"按需加载"边界被侵蚀——部分 reference 内容（码表、修饰）又在主文件复述一遍。

### 🟡 P2 — 三份副本手工同步风险
本次多次出现"改了主副本、忘了同步其他两份"的隐患（已靠最终 MD5 校验兜住）。计划要求每步都做三副本 MD5 校验。

---

## 三、分步优化计划

> 原则：**每步独立可验收、可单独回退**；先修"会让 Agent 直接失败"的 P0，再做结构性去重。

### 步骤 0：建立基线与回退点（无内容改动）
- 记录 3 份副本的 MD5 基线，另存一份完整备份到 `备份/skill优化前_2026-11-19/`。
- 产出：`skill基线.md`（含每文件 MD5、行数、本计划引用）。
- 验收：备份目录存在，MD5 表齐全。

### 步骤 1：替换幽灵工具引用（P0，最高优先）
- 把 skill 中所有 `_tools\sidc.js` / `sidc-check.py` / `orbat.js` / `check_annotations.py` 命令替换为现行工具：
  - 查码 → 改为"读 `reference/sidc-codes.md` 全量表 + `orbat-cli.exe audit` 交叉验证"
  - 校验 → `orbat-cli.exe validate <json>`（红牌 exit 3）
  - 出图 → `orbat-cli.exe render --in <json> --out <基名>`；脚本路径统一为 `app/runtime/render_orbat.js`
- `out of the box` 模式三零 Key 流程与 `MODE3-AGENT-QUICKSTART` 对齐。
- 涉及文件：SKILL.md、checklists.md、workflows.md、legacy.md、soviet-warsaw.md、sidc-codes.md。
- 验收：全 skill 目录 grep 不到 `_tools\sidc.js|sidc-check.py|_tools\orbat.js|check_annotations.py`；`render_orbat.js` 路径全部为 `app/runtime/`。

### 步骤 2：统一注释长度口径为 12 汉字/20 字母（P0）
- SKILL.md 4 处、checklists.md 1 处的 "≤24 汉字" 改为 "≤12 汉字 / ≤20 字母（英文等拼音文字按字母计）"，注明依据 `schema_rules.dart`。
- 与 MODE3 文档、prompt.dart、schema_rules.dart 完全对齐。
- 验收：全 skill grep 不到"24 汉字"；口径与 `schema_rules.dart` 的 `kNoteMaxCjk=12/kNoteMaxLetters=20` 一致。

### 步骤 3：建立"单一信源"，消除规则重复（P1，核心去重）
把散落的全局规则收敛为**唯一定义 + 引用**：
- **修饰位禁用 / 站点语义 / 梯队码 / 命名铁律**的权威定义只留在 `SKILL.md` 的"全局规范"一节。
- 各 reference 文件里对应段落改为一行引用："见 SKILL.md §全局规范"，不再复述全文。
- 具体收敛清单：
  - `sidc-codes.md`：删掉"历史修饰表"3 节（类型/机动/扇区），压缩为一句"修饰位已禁用，历史取值见 legacy.md"；主实体表保留。
  - `checklists.md`/`workflows.md`/`legacy.md`/`soviet-warsaw.md`：出图硬规则改为引用 SKILL.md「强制工作流」。
  - `us-bct.md`/`soviet-warsaw.md`：梯队码表改为引用 `sidc-codes.md`，只保留各项目**特有的**规模码差异（如美军班=13）。
- 验收：每条全局规则在 skill 内只出现 1 处完整定义；引用处能明确指向信源。

### 步骤 4：隔离历史数据，防止误抄（P1）
- 把 `us-bct-templates.md` 里 30+ 处带修饰的历史 SIDC 统一加前缀标注（如 `【历史·勿抄】`），或移入新的 `reference/historical-codes.md`。
- 历史文件顶部声明升级为醒目 box，明确"本文件所有 30 位码均为历史数据，新数据一律主实体后 14 位全 0"。
- 验收：外部 Agent 读任一历史示例都不会误当成新数据模板（人工抽查 + grep 标注覆盖率）。

### 步骤 5：SKILL.md 瘦身（P2）
- 主文件目标：从 326 行压到 ~180 行，只留"骨架 + 公式 + 全局规范 + 工作流 + 自检清单"。
- 码表明细、修饰沿革、项目约定全部只在 reference。
- 验收：SKILL.md 行数下降，且所有被移走内容都能在 reference 找到对应章节（无信息丢失）。

### 步骤 6：三副本同步 + 全量验收（每步都要做，本步总验收）
- 主副本改完后 `cp -r` 同步到 `app/.agents/` 与 `版本/v0.3.5-beta/.agents/`，三份 MD5 必须一致。
- 端到端验证：让外部 Agent 用**只改后的 skill** 重跑一次模式三纯文本测试（复用现有 `模式三测试_v0.3.5` 素材），确认：
  - 不再引用幽灵工具、注释按 12 字、修饰位全 0、出图成功。
- 更新转交文件记录本次优化。

---

## 四、预期收益

1. **可执行性**：消除幽灵工具，外部 Agent 按 skill 操作不再撞"命令不存在"。
2. **一致性**：注释长度、修饰位、站点语义三处口径与软件代码完全统一。
3. **可维护性**：全局规则单一信源，以后改规则只改 1 处（本次改修饰位动了 6 个文件的痛点消除）。
4. **防误抄**：历史数据与新规范物理隔离，降低按旧模板写新数据的风险。
5. **加载效率**：SKILL.md 瘦身，外部 Agent 首屏读到的都是现行有效规则。

## 五、风险与回退

| 风险 | 缓解 |
|---|---|
| 去重后引用断裂（指向不存在的章节） | 步骤 3 逐条核对引用目标；步骤 6 端到端验证 |
| 历史数据误删 | 步骤 4 只加标注/移动，不改码值本身；步骤 0 有完整备份 |
| 三副本漏同步 | 每步结束做 MD5 校验，写进验收标准 |
| 外部 Agent 有别处缓存的旧 skill | 交付时提醒：以项目根 `.agents/` 为唯一正本 |

---

## 六、待确认事项（实施前）

1. **历史码归属**：步骤 4 是把历史 SIDC 加标注留在原文件，还是新建 `reference/historical-codes.md` 集中存放？（计划默认"加标注"，改动更小）
2. **SKILL.md 瘦身力度**：步骤 5 目标 ~180 行是否合适，还是先只做步骤 1-4、瘦身暂缓？
3. **是否需要同步更新 MODE3 文档**：MODE3 快速上手已基本对齐软件，但其中"注释 ≤12 字"与 skill 统一后，是否要在 MODE3 里加一句"完整规则见 skill"的指引？
