# 安卓端 Agent 插件指导 —— 把「编制生成器」当外挂插件用

> 写给手机本机运行的外部 Agent：你（Agent）负责读资料、得出编制描述、生成编制 JSON；
> 「编制生成器」App（orbat_core）负责**本地校验 + 出图（PNG/SVG）**。
> 你与 App 之间通过公共 Download 下的**固定交接目录**交换文件，全程无需人工干预
> （首次使用需人工授权一次「所有文件访问」）。

---

## 一、目录协议（固定，不可更改）

```
/storage/emulated/0/Download/
├── orbat_inbox/          ← 你把编制 JSON 放这里（App 处理完会把源文件移入 done/）
│   └── done/             ← 已处理归档
├── orbat_outbox/         ← App 把产物写到这里（你从这里取结果）
└── orbat_docs/           ← App 导出的 Agent 提示词（agent_prompts.txt）
```

| 文件 | 说明 |
|---|---|
| `<名>.json`（你写入 inbox） | 编制树 JSON，结构见第三节 |
| `<名>.normalized.json`（outbox） | App 按 7 键规范归一化后的 JSON（渲染器要求的标准形） |
| `<名>.report.json`（outbox） | **校验报告**：红牌/警告/出图结果（见第四节） |
| `<名>.png` / `<名>.svg`（outbox） | 出图产物（PNG 为 2x 白底，SVG 为矢量） |

## 二、你的工作流（自修复循环）

```
1. 读用户资料 → 形成明确的编制描述（层级、番号、兵种、注释）
2. 按第三节规范生成编制 JSON（含 7 键 options）
3. 把 JSON 写入 orbat_inbox/<名>.json
4. 打开 App → 顶栏 ⋮ 更多 → 「插件处理 · Agent 交接」
   （App 自动逐个：归一化 → 校验 → 出图；处理中会弹出渲染页，勿离开应用）
5. 读 orbat_outbox/<名>.report.json：
   - red 非空 → 修正 JSON → 回到第 3 步（自修复循环）
   - red 空 → 校验通过，PNG/SVG 已产出，交付用户
6. 「导出 Agent 提示词」可在 orbat_docs/agent_prompts.txt 取得完整
   SIDC 规范与识图工作流提示词（交给你的模型用）
```

注意：
- 第 4 步是**用户/你触发的一次批处理**：一次点按处理 inbox 里全部 JSON。
- 处理过程中 App 会弹全屏渲染页（联网渲染 15~60 秒/个），**期间不要离开应用**，
  否则该文件的报告会记为"出图被取消"（产物可能仍已写出，建议重跑确认）。
- 已存在的同名产物会被覆盖。

## 三、编制 JSON 规范（核心要点）

```json
{
  "name": "第5合成师",
  "sidc": "130310001512110000000000000000",
  "children": [
    { "name": "第1合成营", "sidc": "...", "children": [] }
  ],
  "options": {
    "sidc": "...（同上，30 位）",
    "uniqueDesignation": "第5合成师",
    "additionalInformation": "注释 ≤12 汉字 / ≤20 字母",
    "dashed": false,
    "showMapLabels": true,
    "commandLevels": "1",
    "actorType": ""
  }
}
```

硬规则（违反 = 红牌，校验不过）：
- **SIDC 必须 30 位**，且主实体 6 位之后的 14 位（类型 2+机动 2+扇区 2+保留 8）**必须全 0**（禁用一切小标志）
- `uniqueDesignation`（称号）里**不能有空格+左括号**（渲染器会卡死），如 `某连 (测试)` ✗
- `additionalInformation`（注释）≤ 12 汉字 / ≤ 20 字母，**不含**空格+括号、指挥官姓名（师长XXX）、自检说明
- 根节点才可有 `commandLevels`；子节点不带
- 兄弟节点称号不得重复；`110000`（HQ）加机动修饰 98 会被拦
- 层级建议 ≤3、单父直属下属 ≤10（超出为软警告，不拦截）

完整 SIDC 语义与实体码表：`orbat_docs/agent_prompts.txt`（先点「导出 Agent 提示词」）
与仓库 `docs/SIDC权威对照表.md`。

## 四、报告格式（`<名>.report.json`）

```json
{
  "file": "test",
  "ok": true,                    // 校验是否全绿（红牌 0）
  "nodeCount": 25, "depth": 4,
  "red":  [],                    // 红牌：[{path, message}] —— 必须修复后重交
  "warn": [{"path":"根","message":"..."}],   // 软警告：可忽略
  "render": { "ok": true,        // 出图是否成功
              "png": "...orbat_outbox/test.png",
              "svg":  "...orbat_outbox/test.svg" }
}
```

- `ok=true` 且 `render.ok=true` → 流程完成，产物就绪
- `render.ok=false` 且 error 含"被取消" → 处理时离开了应用，重放该 JSON 再跑一次
- `error` 字段出现（无 red/render 键）→ JSON 结构无法解析，检查是否符合第三节

## 五、首次使用（一次性人工设置）

1. 手机安装 orbat_core（debug APK，随 Release 附带或侧载）
2. 首启选界面语言 → 选**模式三 · Agent 插件**（无需 API Key）
3. 顶栏 ⋮ 更多 → 「插件处理 · Agent 交接」→ 按提示在系统设置里
   **允许「所有文件访问」**→ 返回应用
4. 再点一次「插件处理」即可开始（之后无需再授权）

## 六、能力边界（本期）

- 仅支持「JSON 校验 + 出图」；**AI 识图生成**（模式一）在手机端暂由 Agent 侧模型承担
- 交接目录固定在公共 Download 下；App 需要「所有文件访问」权限
- 批量处理按文件名顺序逐个执行；出图依赖网络（spatialillusions.com）
