# 编制生成器 v0.3.5-beta

从编制结构图或文字资料，AI 识图生成标准军标编制 JSON（SIDC 30 位码），再调用线上渲染器产出编制图（PNG + SVG）。

> 测试版（beta）：欢迎试用与反馈，接口与文件格式仍可能调整。

## 本版亮点

- **SIDC 码表全面对齐 spatialillusions.com 官方语义**：全量码表逐项核对，装甲机械化步兵（121102）、摩托化步兵（121104）、自行火炮（130301）等实体映射按站点官方解释修正
- **修饰位新规范**：主实体 6 位之后的 14 位（类型 2 + 机动 2 + 扇区 2 + 保留 8）必须全 0，禁用一切小标志；旧数据中小标志不为 0 时校验器给出警告（不拦截）
- **API Key 加密存储升级**：Windows 上改用系统 DPAPI（按用户加密），不再使用可逆混淆
- **首次启动向导**：选界面语言 → 选使用模式（三模式），模式三（Agent 插件）全程零 API Key
- **内置中英双语教程**：菜单内直接打开，随界面语言切换
- **模式三 Agent 文档**：随包附《MODE3-AGENT-QUICKSTART》（中英），外部 Agent 接入零门槛
- **安卓端源码就绪**：窄屏 UI、WebView 线上渲染出图已实现，正式发布待后续版本

## 下载

| 附件 | 说明 |
|---|---|
| `orbat-generator-v0.3.5-beta-full-setup.exe` | **完整版安装器**（推荐）：内置 node.exe，免装 Node.js，自动装 VC++ 运行库 |
| `orbat-generator-v0.3.5-beta-lite-setup.exe` | 精简版安装器：体积小，出图需自装 Node.js ≥ 24 |
| `orbat-generator-v0.3.5-beta-portable.zip` | 便携版：解压即用，含 node.exe，免安装 |

## 环境要求

- Windows 10 / 11（64 位）
- Edge 或 Chrome（Win10/11 自带 Edge 即可）
- Node.js ≥ 24（**仅精简版需要**；完整版/便携版已内置）
- DeepSeek API Key（模式一/模式二识图需要；模式三不需要）
- 网络：可访问 deepseek.com 与 spatialillusions.com

## 快速开始

1. 安装并启动后，按向导选语言与模式
2. 模式一/二：设置里填 DeepSeek API Key → 导入编制图或文字 → 生成编制 → 出图
3. 模式三（Agent）：`orbat-cli.exe prompts` 导出提示词交给外部 Agent，识图结果 JSON 用 `orbat-cli.exe validate` 校验、`render` 出图
4. 出图报错先跑「环境自检」（更多菜单）

详细说明见随包《发布说明.md》《CLI说明.md》。

## 反馈

遇到问题请附上报错截图与日志（`%APPDATA%\OrbatGenerator\logs\`），通过 Issue 反馈。

## 开源

MIT License · 署名 LStR-40
