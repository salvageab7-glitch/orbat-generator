# 编制生成器 v0.3.0-beta 公开测试版

第一个公开测试版本。从编制结构图自动识别生成标准军标编制 JSON，再渲染出图。

## 三种下载（按需选择一种）

| 包 | 体积 | 适合谁 | 装完还要做什么 |
|---|---|---|---|
| **完整版 Setup** | ~60 MB | 想装完即用 | 已内置 Node.js，自动补 VC++ 运行库；只差申请 [DeepSeek API Key](https://platform.deepseek.com) |
| **精简版 Setup** | ~13 MB | 流量紧张 | 自装 [Node.js ≥ 24](https://nodejs.org) |
| **zip 便携版** | ~16 MB | 免安装场景 | 自装 Node.js ≥ 24 |

> 首次运行若提示"Windows 已保护你的电脑"：点 **更多信息 → 仍要运行**（未签名程序的正常提示）。

## 功能亮点

- **AI 识图**：编制图（截图/扫描件）→ 30 位 SIDC 军标编码 + 树形 JSON
- **反臆造自检**：每个节点要求在原图有对应方框；同构复制结构强制回图逐个确认
- **校验**：SIDC 位数、层级、军标合法性（红牌/警告两级）
- **出图**：军标符号渲染整树 SVG + PNG
- **三种用法**：GUI / 独立 CLI（`orbat-cli.exe`）/ AI Agent 模式（导出识图提示词）

## 环境要求

- Windows 10/11 x64；Edge/Chrome（自带即可）
- 网络：deepseek.com（识图）+ spatialillusions.com（出图）

## 已知限制

- 识图质量依赖原图清晰度；超大图会自动切片
- 未签名程序，SmartScreen 首次运行会提醒

## 反馈

问题请开 [Issue](../../issues/new)，附：错误提示截图 + 日志（`%APPDATA%\OrbatGenerator\logs\`）
