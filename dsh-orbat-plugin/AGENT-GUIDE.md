# ORBAT Agent Guide / ORBAT Agent 使用指南

Use this guide when turning a user-provided order-of-battle image or document into an ORBAT chart. The plugin does not read images: use the current Agent's vision/file capability, then call the ORBAT tools.

> Full contract: `docs/agent-contract/README.md`（0-based SIDC、12/20 注释、修饰位实际行为、commandLevels）and `docs/agent-contract/hq-echelon-table.md`（HQ 用码）。Structure: `schema/orbat.schema.json` (or `orbat-cli.exe schema --out orbat.schema.json`).

Before rendering, users can open **Settings → ORBAT / 设置 → 编制图** to choose a white or transparent PNG background and set or restore the default output directory. SVG output is always transparent. The page's workflow self-check and the `orbat_workflow_self_check` tool run the same Host operation and do not require an API key.

在出图前，用户可以打开 **设置 → 编制图 / Settings → ORBAT**，选择 PNG 白底或透明底，并设置或恢复默认输出目录。SVG 始终为透明背景。页面上的工作流自检和 `orbat_workflow_self_check` 工具调用同一 Host 操作，不需要 API Key。

## Trigger / 触发（Android mode 3）

Default: open the app with mode 3 and storage access; it auto-scans `Download/orbat_inbox`. The `plugin.RUN` intent is optional and requires an ADB/Shizuku-capable host; do not rely on it. First run also asks to open `orbat_core` and grant “All files access” once.

默认：打开 App（模式三 + 存储权限），自动扫描 `Download/orbat_inbox`。`plugin.RUN` 只是可选路径，需要 ADB/Shizuku；首次还会要求打开 `orbat_core` 与“所有文件访问”。

Poll `_status.json` by `runId`; outcomes are in `files[]` and `report.deliverable`. Output files now use `<name>__<runId>.png|svg|...`. On failure/render-not-delivered, read `logTail` or `outbox/<runId>.log.txt` for the app log tail.

## Workflow / 流程

1. Inspect the source at sufficient zoom. Transcribe only units shown or explicitly stated; do not invent missing formations. Keep uncertain readings explicit for the user instead of silently guessing.
2. Build the JSON tree below. Keep each numbered unit as its own node. Do not merge numbered units as `×N`; use that only for genuinely identical, unnumbered units when the source supports it.
3. Call `orbat_validate_json` with either the complete JSON string (`json`) or a file path (`path`; absolute, or relative to the session workspace). Prefer `path` once the JSON is written: it avoids pasting the whole tree into the tool call. Read every returned `issues` item (`path`, `level`, `message`), correct the source JSON, and validate again. Do not render when red issues remain. Warnings still need a reasoned review.
4. Call `orbat_render_json` only after the tree is validated, also preferring `path` over inline `json`. The plugin validates again, normalizes the tree for the renderer, then returns absolute PNG/SVG paths. By default it writes to `<session workspace>\编制插件产物仓库`; a non-empty plugin setting overrides that directory.
5. Call DSH `present` with the exact returned `pngPath` so the user sees the chart. Do not claim a chart was delivered unless `present` succeeds.

> Default output / 默认产物目录：当前会话工作区下的 `编制插件产物仓库`。若在 **设置 → 编制图** 里填了显式目录，以设置为准；工作区不可写时才回退到 `Documents\ORBAT Generator` 或插件私有 `Output`。

## JSON shape / JSON 结构

Every node requires `options.uniqueDesignation` and a 30-digit `options.sidc`. `options.additionalInformation` is optional text, limited to 12 CJK characters or 20 Latin letters; `subOrganizations` is an array of child nodes. The root has `commandLevels` as a string; the renderer normalizer sets its layout value to `"3"`.

```json
{
  "options": {
    "uniqueDesignation": "第1师",
    "additionalInformation": "",
    "sidc": "130310002111000000000000000000"
  },
  "subOrganizations": [
    {
      "options": {
        "uniqueDesignation": "第1旅",
        "additionalInformation": "",
        "sidc": "130310001811000000000000000000"
      },
      "subOrganizations": []
    }
  ],
  "commandLevels": "3"
}
```

The tool accepts the compact source schema above. Before rendering, it fills the renderer's `dashed`, `outline`, `plain-text-mode`, and `showMapLabels` option fields and applies the same display-name adaptation used by the CLI. Do not add `commandLevels` to child nodes.

## SIDC safety checklist / SIDC 校验要点

- SIDC must contain exactly 30 digits. Use the bundled CLI validator as the authority; do not fabricate entity codes when the source is unclear.
- The common prefix is `1303`; symbol set `10` is land and `01` is air. Aircraft, helicopters, and UAVs require air symbol set `01`.
- Echelon, name, and parent-child hierarchy must agree. Use the project's authoritative code tables or source references when available.
- The current project guidance reserves modifier and trailing fields as zeros. Do not add vehicle, mobility, sector, or other modifier flags unless the user changes that rule.
- Avoid a space immediately before `(` in a designation; the public renderer can hang on that form. Keep notes short and factual (≤12 CJK / ≤20 Latin letters); do not place analysis or confidence commentary in the data fields.

## Evidence and user communication / 来源与沟通

- Preserve the source's original numbering and hierarchy. If a label is clipped or ambiguous, report the uncertainty and ask the user rather than making up a unit.
- If the source is a foreign-language chart, use concise Chinese designations where appropriate and preserve useful original names in `additionalInformation`.
- Explain that rendering opens `https://spatialillusions.com/unitgenerator` in a local browser and imports the JSON into that public page. The renderer's remote retention/processing behavior has not been independently assessed.
- The tools return bounded validation details. If `issuesTruncated` is true, use `issueCount` and request a narrower correction pass; never assume the omitted issues are clear.

此指南供新 Agent 快速理解工作边界：先读图、严格按来源建树，再调用校验/出图工具；不确定信息要询问用户，不要臆造。插件只处理 JSON 与本机渲染，不替代视觉识别或军事编制判断。
