# Android 真机测试记录（2026-11-27）

> 设备：荣耀 MagicPad2（`ROD2-W09`），Android **16** / API **36**。
> APK：`版本/v0.3.6-android/orbat-generator-v0.3.6-debug-signed.apk`（versionCode 306，debug 签名）。
> 连接方式：USB；本机需 `ADB_LIBUSB=1` 才能识别该设备的通用 WinUSB ADB 接口。

## 1. 连接与安装

| 项 | 结果 |
|---|---|
| `adb devices` | `A7TJBB4717001076  device`（需 `ADB_LIBUSB=1`） |
| 型号 / 系统 | `ROD2-W09` / Android 16 / API 36 |
| 首次安装 | `Success` |
| 覆盖安装 `adb install -r` | `Success`；versionCode 306，数据/产物保留 |
| 启动 | `MainActivity` 前台，无崩溃 |

## 2. 模式二禁用

| 场景 | 结果 |
|---|---|
| 首次启动模式选择 | 模式二卡片显示“（安卓暂不支持）”，灰色不可选 |
| 设置 → 工作模式下拉 | 模式二选项灰色禁用 |
| 点击模式二菜单项 | 无效果，仍保持模式三 |
| 旧配置回退 | 代码已处理：Android `mode==1` 启动回退模式一 |

## 3. 权限

| 场景 | 结果 |
|---|---|
| 撤销 `MANAGE_EXTERNAL_STORAGE` 后触发插件 | 自动打开“所有文件访问权限”系统页，未处理 JSON |
| 重新授予后触发 | 正常处理，产物写入 outbox |
| 通知栏权限提示 | 正常，无崩溃 |
| API < 30 传统权限 | 代码已加入 `WRITE_EXTERNAL_STORAGE` + legacy；本机 Android 16 未覆盖 |

## 4. 模式三：热启动

输入：`样例/101st_airborne_2026.json`（44 节点）。

```text
outbox/test101.png            505,600 bytes
outbox/test101.svg             78,821 bytes
outbox/test101.normalized.json 16,837 bytes
outbox/test101.report.json        344 bytes
inbox/done/test101.json
```

报告：

```json
{"ok":true,"nodeCount":44,"depth":3,"red":[],"warn":[{"path":"根/师部及师部营","message":"名称层级词对应 16，但 SIDC 梯队段是 15（「师部及师部营」）"}],"render":{"ok":true,"png":".../test101.png","svg":".../test101.svg"}}
```

`_status.json`：`{"state":"idle","lastRun":{"total":1,"validated":1,"rendered":1,...}}`。

PNG 已人工查看：44 节点编制树、军标、层级正常。

## 5. 模式三：冷启动

```powershell
adb shell am force-stop com.orbat.orbat_core
adb shell am start -a com.orbat.orbat_core.plugin.RUN -n com.orbat.orbat_core/.MainActivity
```

结果：`test101_cold` 同样产出 PNG/SVG/normalized/report，源文件归档到 `done/`。

## 6. 红牌阻断（发现并修复）

测试输入：31 位 SIDC 的 JSON。

**修复前**：报告 `ok=false`，但仍生成 PNG/SVG（违反“红牌不得出图”）。

**修复后**（`app/lib/services/plugin_bridge.dart`）：

```json
{"ok":false,"red":[...],"render":{"ok":false,"skipped":true,"reason":"存在红牌错误，已跳过出图"}}
```

- outbox 只有 `report.json` 与 `normalized.json`，**没有 PNG/SVG**。
- 源文件移入 `done/`。
- 重新推送合法 JSON，模式三出图仍正常。

## 7. 模式一 UI 冒烟

- 设置 → 工作模式切到“模式一 · 纯软件”成功。
- API Key 输入框变为可编辑，提示“仅存于本机配置文件”。
- 未实际调用 DeepSeek（无 Key）；完整识图/出图/分享仍待验证。
- 测试后已通过 `pm clear` + 首启选择回到模式三。

## 8. 未覆盖

- Android 15（实测设备为 Android 16）。
- Android 10/13 兼容。
- 模式一完整识图/出图/分享（需 Key）。
- 旋转/后台/进程重建/低内存。
- 批量 100/扫描 2000/10 MiB 上限。
- 正式 release keystore（当前 debug 签名）。

## 9. 主界面进度条（隐藏渲染器）

需求：点击“出图”时不要显示线上渲染器，WebView 在后台运行，进度条显示在**主界面输出目录下方**。

实现：

- `app/lib/ui/home_page.dart`：WebView 挂在主界面底层，被不透明的 Scaffold 遮住；不再跳转 `RenderWebViewPage`（该页已删除）。
- 进度复用在输出目录下方的 `_buildRenderProgress`：阶段名、百分比、耗时、最近日志。
- 窄屏自动切到“预览”分页，保证进度可见。

实测：

- 出图中主界面正常显示，右侧输出目录下方出现“等待站点初始化 34% 3.5s”，**没有站点页面**。
- 约 20 秒后完成；`bgtest.report.json` 显示 `ok=true`、44 节点、PNG 505,600 B + SVG。
- 进度条不影响模式三/手动出图结果。

## 10. 内置样例结构 + 出图自检

需求：环境检测使用随包发布的测试 JSON 验证结构解析与出图，结束后自动删除测试图。

实现：

- 资产：`app/assets/test/smoke_orbat.json`（3 节点，随 APK 发布）。
- `app/lib/core/self_check.dart`：新增 `androidSmoke` 回调，Android 不再跳过出图冒烟。
- `app/lib/ui/home_page.dart`：加载资产 → 解析/校验 → 隐藏 WebView 出图 → 校验 PNG → 删除临时测试产物。

实测截图（环境正常对话框）：

```text
✓ 内置样例结构 + 出图
  3 节点 / 深度 2；PNG 24KB（测试图已自动删除）
```

测试目录为临时目录，结束后递归删除；用户正常产物不受影响。

## 11. Agent 状态与产物（P0 验证）

| 项 | 实测 |
|---|---|
| 启动空闲状态 | `{"state":"idle","runId":null,"triggerAt":null,...}` |
| 触发后 | `queued` + `runId` + `triggerAt`；随后 `running`；结束 `done` |
| 每文件摘要 | `files[]` 含 `ok/red/render/deliverable/png/svg/report` |
| 自动扫描 | force-stop 后仅 `am start -n`（无 intent）+ inbox 文件 → 8 秒 `done`，无需 ADB/Shizuku |
| 产物命名 | `bgtest__20261127-200023-616309.png` 等；同名不覆盖 |
| 红牌 | `deliverable=false`、`render.skipped=true`、无 PNG/SVG |
| PNG 质量 | `quality.ok=true`、`4316×1064`、非背景 `9.93%` |

## 12. P1 契约验证

| 项 | 实测 |
|---|---|
| `agent_prompts.txt` 头部 | `PROMPT_VERSION: 2026-11-27-p1`、`COMMENT_LIMIT: 12 CJK / 20 letters`、`SIDC_BASE: 0-based` |
| commandLevels 输入 2 | report `commandLevelsInput:"2"`、`commandLevelsOutput:"2"` |
| commandLevels 输入 1 | report `commandLevelsInput:"1"`、`commandLevelsOutput:"3"` |
| HQ 用码 | `docs/agent-contract/hq-echelon-table.md` |
| 0-based 位号 | skill playbook / sidc_tables / SIDC 对照表统一 |
| 错误日志 | `failed`/渲染未交付时 `_status.json` 提供 `log/logTail`，并写 `outbox/<runId>.log.txt` |

## 13. 指挥层级设置（commandLevels 2/3）

| 场景 | 实测 |
|---|---|
| 设置页入口 | 顶部齿轮 →「指挥层级 commandLevels」 |
| 默认值 | `3 · 默认（推荐）`，附“2 仅用于特殊宽树，可能反而更宽；会覆盖 JSON 根节点”说明 |
| 切换 2 并保存 | 设置页显示 `2 · 特殊宽树`；重开 App 后仍为 2（配置持久化） |
| 设置 2 + JSON 输入 3 | report `commandLevelsInput:"3"`、`commandLevelsOutput:"2"`、`commandLevelsSource:"settings"` |
| 设置 3 + JSON 输入 2 | report `commandLevelsInput:"2"`、`commandLevelsOutput:"3"`、`commandLevelsSource:"settings"` |
| 出图 | 两种设置下 `deliverable=true`，PNG 682×396、质量检查通过 |
| 最终状态 | 已恢复为默认 3 |
| 提示词版本 | `agent_prompts.txt` 重写为 `PROMPT_VERSION: 2026-11-27-p2`（骨架 commandLevels=3） |

## 14. API 地址与版本号

| 项 | 实测 |
|---|---|
| 设置页底部 | 显示 `软件版本 v0.3.6` |
| API 地址字段 | 默认 `https://api.deepseek.com`；可改为 `https://api.openai.com/v1` 等 OpenAI 兼容地址 |
| 编辑保存 | 改为 OpenAI `/v1` 后保存，重开设置仍保留；随后恢复 DeepSeek 默认 |
| 模式三可编辑 | 模式三下 Key / API 地址 / 模型均可预先配置，切到模式一/二后生效 |
| 服务类型 | DeepSeek / OpenAI 兼容（含 OpenCode Go）；切到 OpenAI 后 DeepSeek 预设隐藏 |
| 读取模型列表 | Android 填临时 Key + OpenCode Go 后成功：31 chat / 25 vision；下拉显示名称、id、vision |
| OpenCode Go 预设 | 点击后 API 地址变为 `https://opencode.ai/zen/go/v1` |
| 测试后状态 | 已取消设置并恢复 DeepSeek 默认；测试 Key 未保存 |
| 版本号 | 设置页底部显示 `软件版本 v0.3.6` |
| Go 实网（Windows CLI） | 文本生成 3 节点/0 红牌；视觉图片生成 3 节点/0 红牌 |
| Go 模型列表 | 31 个 chat 模型，25 个 vision 标记 |
| 模式三回归 | 恢复模式三后，`clapi` 3 节点样例 `deliverable=true`，PNG 682×396 |
| report | `commandLevelsInput:"3"`、`commandLevelsOutput:"3"`、`commandLevelsSource:"settings"` |

## 15. 环境备注

- 本机 adb 无法直接识别该设备；需设置 `ADB_LIBUSB=1`。
- 设备屏幕物理 1920×3000，Flutter 横屏逻辑 3000×1920；`input tap` 使用后者坐标。
- 测试文件已从设备 `Download/orbat_inbox|outbox` 清理；App 保留模式三与权限。
