# 编制图生成器

把编制图图片或文字资料，通过 DeepSeek 转写成结构化 ORBAT JSON，再调用线上渲染器出图。
目标平台：Windows、Android。

## 目录结构

```
app/
  lib/
    core/         # 核心规则引擎（纯 Dart，无 Flutter 依赖）
      sidc_tables.dart    # 手写中文码表 + 关键词映射
      sidc_entities.dart  # milsymbol 全量实体码（自动生成，勿手改）
      sidc.dart           # SIDC 构造/解析/解读
      sidc_rule.dart      # 名称 → SIDC 规则引擎（中/英/俄层级词与兵种词）
      sidc_audit.dart     # 模型码与本地规则的一致性审计
      schema_rules.dart   # 字段硬规则（注释 12 汉字 / 20 字母等）
      auto_fix.dart       # 机械修复（SIDC 位数、括号、注释长度、兄弟去重）
      patch_repair.dart   # 补丁式修复（只改字段，绝不重写整棵树）
      dup_scan.dart       # 跨父节点同名扫描与合并
      app_paths.dart      # 输出目录约定（exe 同级「输出文件存档」）
      orbat.dart          # 数据模型、7 键归一化、红牌校验
      self_check.dart     # 环境自检（含出图冒烟）
    ai/
      prompt.dart          # system prompt（规则固化）
      deepseek_client.dart # DeepSeek 客户端（视觉 + JSON Output + 兜底 + 错误分类）
    render/
      renderer.dart        # 调用线上渲染器出图
    pipeline.dart          # 业务编排（分块识图 → 合并 → 审计 → 校验 → 补丁修复）
    services/
      settings_store.dart  # 配置存储（API Key、脚本路径、语言、开关）
    i18n/
      l10n.dart            # 界面语言字典（中文原文作 key，纯 Dart）
    ui/
      home_page.dart       # 主界面
      tree_view.dart       # 编制树可视化（支持就地编辑单位）
      l10n_ui.dart         # 语言切换通知器
    main.dart
  runtime/                 # 随软件分发的渲染脚本（Node，仅用内置模块）
    render_orbat.js
    cdp.js
  test/                    # 自检与端到端测试
  docs/                    # 踩坑记录
```

## 功能概览

- 识图/文字 → ORBAT JSON（DeepSeek 视觉，分块识图 + 结构合并）
- 本地规则引擎生成/校正 SIDC，并做名称-码一致性审计
- 红牌校验 + 补丁式修复（不重写整棵树，避免丢节点）
- 调用线上渲染器出 PNG/SVG，产物落在 `软件目录\输出文件存档\`
- 界面支持中英切换；树视图可就地改名称/注释/编码
- 模式三（外部 Agent 识图，无需 API Key）：见 `docs/MODE3-AGENT-QUICKSTART.zh.md` / `.en.md`
- CLI（`orbat-cli.exe`）供外部 Agent 调用：`generate / validate / audit / edit / render / batch / selfcheck`

## 环境要求

| 项 | 要求 | 用途 |
|---|---|---|
| Flutter | 3.50+ | 构建 Windows / Android 界面 |
| Visual Studio | 2022 生成工具 + C++ 工作负载 | Windows 桌面构建必需 |
| Node.js | **≥ 24** | 出图脚本（低版本会无界挂起） |
| Chrome / Edge | 任意近期版本 | 出图时由脚本自动驱动 |
| DeepSeek API Key | — | 填写在软件设置里 |

Android 构建另需 Android SDK + JDK。

## 开发运行

```bash
cd app
flutter pub get
flutter run -d windows
```

## 构建

### ⚠️ 中文路径会卡住 Release 构建

`flutter build windows --release` 在**含中文的路径**下会失败于 Dart AOT 阶段：
```
CUSTOMBUILD : error : Unable to read file: ...app.dill
```
原因是 MSBuild 在 GBK 代码页下解析 UTF-8 路径出错。`--debug` 不受影响。

**解法**：把项目复制到纯 ASCII 路径构建，产物再拷回。

```bash
# 在 ASCII 路径构建
cp -r lib windows android runtime test pubspec.yaml pubspec.lock <ASCII 构建目录>/
cd <ASCII 构建目录> && flutter pub get && flutter build windows --release

# 部署脚本并回拷
cp -r runtime build/windows/x64/runner/Release/
cp -r build/windows/x64/runner/Release/* "<目标目录>"
```

### Debug 构建（中文路径下可用）

```bash
cd app
flutter build windows --debug
```

产物在 `build/windows/x64/runner/Debug/`。**必须把 `runtime/` 复制到该目录**，
否则出图提示找不到脚本。程序也会自动探测 exe 同级的 `runtime/`。

Android：
```bash
flutter build apk --release
```

## 自检（不需要 Flutter，纯 Dart 即可跑）

```bash
cd app
dart run test/engine_selfcheck.dart   # 核心引擎，30 项
dart run test/ai_selfcheck.dart       # AI 模块，15 项
```

## 端到端测试

```bash
# 1) 真实 API 识别（会花钱，一次几分钱）
DEEPSEEK_API_KEY=sk-xxx dart run test/live_api.dart <图片.png> out.json

# 2) JSON 出图（需联网 + node ≥ 24）
dart run test/e2e_render.dart out.json <输出基名>
```

## 关键设计

- **SIDC 主实体码语义依赖符号集**：`10`=陆地用 `13031000` 前缀，`01`=空中用 `13030100`。
  校验器按符号集查不同的全量表。详见 `docs/踩坑与设计决策.md`。
- **出图只走线上渲染器**：spatialillusions 的排版算法闭源，本地无法 1:1 复现。
- **自我修复循环**：生成后本地校验，有红牌就把具体错误回传给模型修复，最多 2 轮。
- **人工兜底**：JSON 编辑页可直接改，改完校验/出图。
