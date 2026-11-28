# Windows 安装器构建记录（v0.3.7-beta）

## 1. 产物

| 文件 | 大小 | SHA-256 |
|---|---:|---|
| `orbat-generator-v0.3.7-beta-full-setup.exe` | 60,042,502 | `d3e7f00a8459deea9828318c472908bf399ffa9d30d7cbfcef7327c7874c062c` |
| `orbat-generator-v0.3.7-beta-lite-setup.exe` | 13,769,040 | `eea16ee07b3de999bbec7729ba63198db69fd9daad0599c1ba410336e826af7a` |

- 位置：`版本/v0.3.7-beta/release/`
- 已上传 GitHub Release `v0.3.7-beta`
- 未做商业代码签名；SmartScreen 可能提示未知发布者

## 2. 构建

- Flutter Windows release：`C:\bld\win037`
- 安装器脚本：`发布物料/安装器脚本/完整版-0.3.7-beta.iss`、`精简版-0.3.7-beta.iss`
- Inno Setup 7.1.1
- 沿用 0.3.6 AppId：`{{7A1F2C33-9D4E-4B58-A6C2-1E9F0B8D5A44}}`（覆盖升级）
- 完整版内置：
  - `node.exe`（`C:\bld\installer_staging_037\node.exe`）
  - `vc_redist.x64.exe`（缺失时静默安装）
- 精简版不包含 Node/VC++，需用户自备 Node ≥24

## 3. 安装测试

静默安装到临时目录：

```text
C:\orbat-build-test\install037-full
C:\orbat-build-test\install037-lite
```

结果：

| 项 | 完整版 | 精简版 |
|---|---|---|
| 安装退出码 | 0 | 0 |
| `orbat-cli.exe --version` | `0.3.7-beta` | `0.3.7-beta` |
| `启动.exe` | 存在 | 存在 |
| `runtime/render_orbat.js` | 存在 | 存在 |
| `bin/node.exe` | 存在（92 MB） | 不存在 |
| 启动主程序 4 秒 | 正常驻留 | 正常驻留 |
| 静默卸载 | 退出码 0 | 退出码 0 |

安装/卸载后已清理临时目录。

## 4. 发布

- GitHub Release：https://github.com/salvageab7-glitch/orbat-generator/releases/tag/v0.3.7-beta
- 附件：full-setup / lite-setup / DSH 插件 zip+tgz / Android APK / SHA256SUMS
- 源码提交：`0582a54`（后续文档提交 `e96ef10`）

## 5. 注意

- 完整版体积较大（60 MB），内含 Node；精简版 13.8 MB。
- 安装包未签名；发布页需保留 SHA-256 校验。
- Windows 10/11 64 位；WebView2/Edge 由系统 Edge 提供。
