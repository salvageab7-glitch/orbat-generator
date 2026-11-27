# Android 构建记录（v0.3.6 侧载版）

> 日期：2026-11-27
> 决策：仅侧载；继续 debug 证书；模式二标记不支持。
> 状态：**APK 已构建/已签名；Honor MagicPad2 / Android 16 真机验证通过**。

## 1. 产物

| 项 | 值 |
|---|---|
| 文件 | `版本/v0.3.6-android/orbat-generator-v0.3.6-debug-signed.apk` |
| 大小 | 54.69 MB |
| 包名 | `com.orbat.orbat_core` |
| versionName | `0.3.6` |
| versionCode | `306` |
| minSdk / targetSdk | `24` / `36` |
| ABI | arm64-v8a / armeabi-v7a / x86_64 |
| 签名 | Android Debug（`CN=Android Debug`） |
| 证书 SHA-256 | `6c99c46639ad021c85a245cf81eb0ce9723fa324091178a9189187f312275e9b` |
| APK SHA-256 | `36118DF6B81F1B6A6E8318C0132D27E98FF74FBBF7C0D0BDAE9138D2897D1BEA` |

## 2. 构建环境

- Flutter 3.50.0 / Dart 3.14.0
- Android SDK 36.0.0，build-tools 36.0.0
- JDK 17（Temurin 17.0.21+9）
- 构建路径：`C:\orbat-android-build`（纯 ASCII）
- 中文路径下 `app.dill` 读取失败，**必须**在 ASCII 路径构建。

## 3. 构建命令

```powershell
# 在 ASCII 工作区
C:\flutter\bin\flutter.bat pub get
C:\flutter\bin\flutter.bat build apk --release
```

产物：`build\app\outputs\flutter-apk\app-release.apk`

签名/版本校验：

```powershell
$env:JAVA_HOME = 'C:\Users\胡宇晨\AppData\Local\Programs\jdk-17.0.21+9'
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\apksigner.bat" verify --print-certs app-release.apk
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\aapt.exe" dump badging app-release.apk
```

## 4. 本次代码改动

| 文件 | 改动 |
|---|---|
| `app/android/app/src/main/AndroidManifest.xml` | 增加 `WRITE_EXTERNAL_STORAGE`（maxSdk 29）、`requestLegacyExternalStorage=true` |
| `app/android/app/src/main/kotlin/.../MainActivity.kt` | API < 30 检查/申请传统存储权限；`onRequestPermissionsResult` 回传 |
| `app/android/app/build.gradle.kts` | 缺少 `ORBAT_RELEASE_*` 时输出 debug 签名警告 |
| `app/pubspec.yaml` | `version: 0.3.6+306`（versionCode 306） |
| `app/lib/main.dart` | Android 旧配置模式二回退模式一 |
| `app/lib/ui/home_page.dart` | 模式二卡片在 Android 禁用；权限提示文案 |
| `app/lib/i18n/tutorial_text.dart` | 模式二标注“仅桌面端；Android 不支持” |
| `app/lib/i18n/l10n.dart` | 新增模式二/权限提示英文 |
| `app/lib/services/plugin_bridge.dart` | 红牌跳过渲染；runId/artifactBase/deliverable；固定目录+时间戳后缀；PNG quality |
| `app/lib/render/renderer.dart` | PNG 质量检查（尺寸/非空白）、`RenderQuality` |
| `app/lib/render/webview_renderer.dart` | 写 PNG 前做质量检查 |
| `app/lib/ui/home_page.dart` | 启动 idle runId=null；queued/running/done 状态；每文件摘要；自动扫描诊断 |
| `app/lib/ai/prompt.dart` | prompt 契约版本、HQ 用码 |
| `app/lib/core/sidc_tables.dart` | 0-based 位号注释 |
| `docs/agent-contract/` | Agent 单一规则源/HQ 表 |
| `app/lib/ui/home_page.dart` | WebView 隐藏在主界面底层；输出目录下方显示进度条；内置样例自检 |
| `app/lib/core/self_check.dart` | Android 出图冒烟改走 `androidSmoke` 回调；AI 连通检查读取实际 API 地址 |
| `app/lib/services/settings_store.dart` | config v9：`apiBaseUrl`、`commandLevels`；默认 DeepSeek |
| `app/lib/ai/deepseek_client.dart` | 支持 OpenAI 兼容 `/v1` 地址；`thinking` 仅 DeepSeek |
| `app/lib/ui/home_page.dart` | 设置页 API 地址/Key/模型、commandLevels、底部版本号 |
| `app/assets/test/smoke_orbat.json` | 随包发布的 3 节点测试 JSON |
| `app/lib/ui/render_webview_page.dart` | 已删除（改为主界面进度条） |

## 5. 已验证

- [x] APK 构建成功（ASCII 路径）
- [x] `apksigner verify` 通过（debug 证书）
- [x] versionCode=306 / versionName=0.3.6 / minSdk 24 / targetSdk 36
- [x] `WRITE_EXTERNAL_STORAGE maxSdk 29` 已打包
- [x] `dart analyze lib` 0 error / 0 warning（63 条 info）
- [x] `engine_selfcheck` 30/30；`ai_selfcheck` 15/15；`stability_selfcheck` 23/23
- [x] 单一信源 `--check --skills` OK
- [x] 真机安装 + 覆盖安装（Honor MagicPad2 / Android 16 / API 36）
- [x] 权限拒绝 → 打开“所有文件访问权限”页；授予后正常
- [x] 模式三热启动：44 节点 → PNG 505,600 B + SVG + report
- [x] 模式三冷启动：force-stop + `plugin.RUN` 成功
- [x] 主界面进度条：不显示线上渲染器，输出目录下方显示阶段/百分比/耗时
- [x] 环境自检内置样例：3 节点/深度 2，PNG 24KB，测试图自动删除
- [x] Agent 状态：idle(runId=null)→queued→running→done；含 triggerAt/files[]
- [x] 自动扫描：force-stop 后仅 `am start -n` + inbox → 8 秒 done
- [x] 产物命名：`<base>__<runId>.png/svg/...`，同名不覆盖
- [x] PNG 质量：尺寸/非空白检查（44 节点 9.93%）
- [x] 红牌 JSON：`render.skipped=true`、`deliverable=false`，无 PNG/SVG
- [x] `agent_prompts.txt` 带 `PROMPT_VERSION: 2026-11-27-p2`/`COMMENT_LIMIT`/`SIDC_BASE`
- [x] `commandLevels` 真机：输入 2 → 输出 2；输入 1 → 输出 3，report 记录 Input/Output
- [x] 设置页可选 `commandLevels` 2/3（默认 3，附推荐说明）；设置覆盖 JSON 根节点，report 标 `commandLevelsSource:"settings"`
- [x] 设置页底部显示 `软件版本 v0.3.6`
- [x] 支持任意 OpenAI 兼容 API：可配置 API 地址 + Key + 模型 id；默认仍为 DeepSeek
- [x] 设置页“服务类型” DeepSeek / OpenAI 兼容；非 DeepSeek 隐藏 DeepSeek 预设
- [x] “读取模型列表”：标准 `/models` + OpenCode Go metadata（chat/vision 标记）；Android 真机成功读取 31 chat / 25 vision
- [x] OpenCode Go：`x-opencode-session` + `thinking:disabled`；Windows CLI 文本/视觉实网通过
- [x] `thinking` 仅对 DeepSeek / OpenCode 地址发送，普通 OpenAI 兼容不携带该字段
- [x] Agent 契约/HQ 表/0-based 文档已收敛
- [x] 失败/渲染未交付时提供 `log/logTail` 与 `outbox/<runId>.log.txt`
- [x] 模式二在 Android 首启/设置中禁用
- [x] 模式一切换后 API Key 输入框可编辑（未实际调用 API）

详细记录：[`docs/android-device-test-2026-11-27.md`](android-device-test-2026-11-27.md)。

## 6. 未验证 / 后续

- [ ] Android 15（实测设备为 Android 16）
- [ ] Android 10/13 兼容
- [ ] 模式一完整识图/出图/分享（需 API Key）
- [ ] 旋转/后台/进程重建/低内存
- [ ] 批量 100 / 扫描 2000 / 10 MiB 上限
- [ ] 正式 release keystore（当前 debug 签名）

## 7. 安装

```powershell
$env:ADB_LIBUSB='1'   # 本机识别该设备需要
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb install -r "C:\Users\胡宇晨\Desktop\编制生成器\版本\v0.3.6-android\orbat-generator-v0.3.6-debug-signed.apk"
```

## 8. 注意

- 这是 **debug 证书签名的 release APK**，仅侧载/测试；不能作为正式发布包。
- 保留 `MANAGE_EXTERNAL_STORAGE`，仅侧载场景；若未来上架 Play，必须另立 SAF feature。
- 模式二在 Android 已禁用；桌面端不受影响。
