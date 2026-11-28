# 文档索引

## Agent 入口

- [`AGENTS.md`](../AGENTS.md) — 最短读取指引（OpenCode 默认加载）
- [`agent-guide.md`](agent-guide.md) — 详细阅读顺序、任务路由、命令
- [`cleanup-2026-11-27.md`](cleanup-2026-11-27.md) — 本次清理记录
- [`android-release.md`](android-release.md) — Android v0.3.6 侧载 APK 构建/签名/验证记录
- [`android-release-0.3.7-beta.md`](android-release-0.3.7-beta.md) — Android v0.3.7-beta 构建记录
- [`windows-release-0.3.7-beta.md`](windows-release-0.3.7-beta.md) — Windows v0.3.7-beta 完整版/精简版安装器记录
- [`android-device-test-2026-11-27.md`](android-device-test-2026-11-27.md) — Android 真机测试记录
- [`../dsh-orbat-plugin/CLI-PROTOCOL.md`](../dsh-orbat-plugin/CLI-PROTOCOL.md) — Windows CLI 协议、`logs`/错误报告、退出码

## Spec Kit 规格

| 目录 | 状态 | 内容 |
|---|---|---|
| [`specs/000-system-baseline`](../specs/000-system-baseline/spec.md) | 已完成 | 当前系统能力、三模式、契约、架构、技术债 |
| [`specs/001-stability`](../specs/001-stability/spec.md) | S6/S3/S4/S7 已实现；S5 待做 | 全局异常、API 分级、动态超时、原子写 |
| [`specs/002-single-source`](../specs/002-single-source/spec.md) | 已完成 | `app/lib` → `cli_aot` 生成/校验 + CI/pre-commit 门禁 |
| [`specs/003-android`](../specs/003-android/spec.md) | Phase 0/1/2 已实现；Honor MagicPad2 / Android 16 真机验证通过 | Android 权限、签名、三模式、真机验证、发布 |
| [`specs/004-agent-mode3-feedback`](../specs/004-agent-mode3-feedback/spec.md) | P0/P1/P2 已实现；P3 待做 | Agent 反馈 19 条 → 代码映射、P0–P3 改进计划 |
| [`specs/005-openai-compatible-provider`](../specs/005-openai-compatible-provider/spec.md) | 已实现；Android Go 列表已真机验证 | 服务类型、模型列表、OpenCode Go session/thinking 适配 |

## 源码级文档

| 文件 | 用途 |
|---|---|
| [`docs/agent-contract/README.md`](agent-contract/README.md) | Agent 单一契约：0-based SIDC、注释 12/20、修饰位、commandLevels |
| [`docs/agent-contract/hq-echelon-table.md`](agent-contract/hq-echelon-table.md) | HQ 用码表（排/连/营/旅/师/军） |
| [`schema/orbat.schema.json`](../schema/orbat.schema.json) | ORBAT JSON 结构契约（CLI `schema` 可导出） |
| [`app/docs/source-of-truth.md`](../app/docs/source-of-truth.md) | 单一信源规则、生成/检查命令、故障处理 |
| [`app/docs/踩坑与设计决策.md`](../app/docs/踩坑与设计决策.md) | 实测事实：SIDC、DeepSeek、渲染、权限、中文路径 |
| [`app/docs/SIDC权威对照表.md`](../app/docs/SIDC权威对照表.md) | 站点码表与业务映射 |
| [`app/docs/skill优化计划.md`](../app/docs/skill优化计划.md) | `orbat-json-writer` 的 P0/P1 优化计划 |
| [`app/docs/安卓端开发计划.md`](../app/docs/安卓端开发计划.md) | 历史 Android 计划；新计划见 `specs/003-android/` |

## 项目级计划与历史

| 文件 | 状态 |
|---|---|
| [`优化计划_v0.5.md`](../优化计划_v0.5.md) | 当前阶段计划；阶段 3 由 `001-stability` 承接 |
| [`优化计划_v0.4.md`](../优化计划_v0.4.md) | 已被 v0.5 取代 |
| [`转交文件.md`](../转交文件.md) | 历史交接文档；现行入口以 `AGENTS.md`/`README.md` 为准 |
| [`迁移记录_2026-11-26.md`](../迁移记录_2026-11-26.md) | 工具链/产物迁移记录 |
| [`CLI接口评估报告-2026-11-21.md`](../CLI接口评估报告-2026-11-21.md) | CLI 接口历史评估 |

## 产物与归档

- `输出文件存档/` — 用户产物（保留）
- `版本/` — 发布快照（v0.3.5-beta、v0.3.6、v0.3.7-beta）
- `发布物料/` — 安装器/教程/发布素材
- `归档/2026-11-27-清理/` — 本次移入的一次性测试产物、探针脚本、旧包、插件产物
- `测量记录/` — 主题切换基线与结果

## 维护规则

- 新功能/优化先建 `specs/NNN-*/`，不要只写散落 Markdown。
- 现行规则只保留一个信源；历史文档加“已被取代”标注并指向新文档。
- 不在根目录新增临时脚本/截图/JSON；放 `归档/` 或对应 `app/test/fixtures/`。
