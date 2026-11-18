# 编制生成器 (orbat-generator)

从编制结构图自动识别生成标准军标编制 JSON，再渲染出图（PNG/SVG）的 Windows 桌面工具。

面向军事爱好者、编制考据与资料整理场景：把「师→旅→营」这类组织架构图
（截图 / 扫描件）交给软件，自动转写为结构化 JSON，并可用军标符号（MIL-STD-2525 风格）
渲染成标准产图。

![产图示例](assets/screenshot.png)

## 功能

- **识图**：AI 识图（DeepSeek 多模态）读编制图，输出 30 位 SIDC 军标编码 + 树形 JSON
  - 内置反臆造自检：每个节点都要求能在原图上找到对应方框，防止「按惯例脑补」多余层级
  - 同构复制检测：多个分支子节点清单完全相同时强制回图逐个确认
- **校验**：`validate` 检查 SIDC 位数、层级深度、军标合法性（红牌=必须修，警告=可忽略）
- **出图**：渲染到 [Battle Staff Tools](https://spatialillusions.com/battlescope/) 生成整树 SVG + PNG
- **三种用法**：GUI 桌面程序 / 独立 CLI（`orbat-cli.exe`，无需 Dart SDK）/ AI Agent 模式
  （导出识图提示词，Agent 自己读图写 JSON，再用 CLI 校验出图）

## 下载

前往 [Releases](../../releases) 页面下载（Windows x64）：

| 包 | 体积 | 说明 |
|---|---|---|
| 完整版 Setup | ~60 MB | 内置 Node.js，自动补 VC++ 运行库，装完即用 |
| 精简版 Setup | ~13 MB | 需自装 Node.js ≥ 24 |
| zip 便携版 | ~16 MB | 解压即用，不写注册表 |

## 环境要求

- Windows 10 / 11 x64
- [Node.js](https://nodejs.org) ≥ 24（仅出图需要；完整版已内置）
- Edge / Chrome 浏览器（Win10/11 自带 Edge 即可）
- [DeepSeek API Key](https://platform.deepseek.com)（仅识图需要）
- 需能访问 deepseek.com 与 spatialillusions.com

## 从源码构建

```bash
# GUI（Flutter Windows）
flutter build windows --release
# 注意：请在纯 ASCII 路径下构建，中文路径可能触发 MSBuild 编码问题

# CLI（纯 Dart，不需要 Flutter）
bash scripts/build_cli.sh <输出路径>
```

## 目录结构

```
lib/            Flutter GUI + 识图/校验/渲染流水线（核心逻辑）
  core/         编制树模型、批量队列、日志
  ai/           DeepSeek 多模态识图客户端、切片流水线
  pipeline.dart 识图主流程（切片→识图→合并→自检）
  render/       出图调度（CDP 控制浏览器）
  cli/          CLI 入口（validate / render / prompts / config）
  services/     配置存储
cli_aot/        CLI 的纯 Dart AOT 编译子项目（构建 orbat-cli.exe 用）
runtime/        出图 Node 脚本（render_orbat.js + cdp.js）
scripts/        构建脚本
```

## 许可证

[MIT](LICENSE)
