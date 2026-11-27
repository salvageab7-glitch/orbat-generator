# Android 构建记录（v0.3.7-beta 侧载版）

## 1. 产物

| 项 | 值 |
|---|---|
| 文件 | `版本/v0.3.7-beta/release/orbat-generator-v0.3.7-beta-android-debug.apk` |
| 包名 | `com.orbat.orbat_core` |
| versionCode | `307` |
| versionName | `0.3.7-beta` |
| 大小 | 57,523,348 字节（约 54.9 MB） |
| 签名 | Android Debug（仅侧载/测试） |
| minSdk / targetSdk | 24 / 36 |
| SHA-256 | `AD1D969EBE2123634CE465AC3412E24A00BC7A368C211744634D6C01518B0B33` |

## 2. 本版 Android 变更

- 设置页新增“服务类型”：DeepSeek / OpenAI 兼容（含 OpenCode Go）。
- 非 DeepSeek 隐藏 DeepSeek 预设；新增“读取模型列表”。
- OpenCode Go：模型列表读取、vision 标记、`x-opencode-session`、`thinking:disabled`。
- `commandLevels` 2/3 设置，默认 3。
- 设置页底部显示软件版本。
- 模式三 P0/P1/P2：状态、deliverable、PNG 质量、时间戳命名、自动扫描、日志诊断、validate-only、Schema 等。

## 3. 构建环境

```text
Flutter/Dart: C:\flutter
Android SDK: %LOCALAPPDATA%\Android\Sdk
build-tools: 36.x
构建目录: C:\orbat-android-build（纯 ASCII）
构建命令: flutter build apk --release
```

`aapt dump badging` 验证：

```text
versionCode='307' versionName='0.3.7-beta'
sdkVersion:'24' targetSdkVersion:'36'
```

## 4. 真机情况

构建时设备未连接（`adb devices` 为空），因此 **v0.3.7-beta APK 未在本轮重新安装到真机**。

上一版 v0.3.6 真机已验证：

- 模式三自动扫描、状态、红牌阻断、PNG 质量、时间戳产物；
- commandLevels 设置；
- OpenAI/OpenCode Go 服务类型、模型列表成功读取（31 chat / 25 vision）；
- 测试 Key 未保存。

建议安装 0.3.7-beta 后补一次冒烟：

```powershell
$env:ADB_LIBUSB='1'
adb install -r "版本\v0.3.7-beta\release\orbat-generator-v0.3.7-beta-android-debug.apk"
```

## 5. 配置迁移

- 配置 schema 升到 v10；
- 旧配置保留，自动补 `providerType`、`commandLevels`、`apiBaseUrl`；
- API Key 仍使用平台安全存储，不写入日志/仓库。

## 6. 已知限制

- debug 签名，不能上架应用商店；
- 普通 OpenAI 兼容服务的 `/models` 能力元数据不统一；
- 插件/Android 出图依赖 `spatialillusions.com` 可用。

## 7. 发布记录

- GitHub Release: https://github.com/salvageab7-glitch/orbat-generator/releases/tag/v0.3.7-beta
- 源码提交: `0582a54`（导出仓库 main）
- 发布附件: DSH 插件 zip/tgz、Android APK、SHA256SUMS.txt
- GitHub Release 已标记 prerelease=true（beta）。
