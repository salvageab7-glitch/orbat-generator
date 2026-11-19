# 安卓端 Agent 测试指导 —— 编制生成器（orbat_core）

> 交给手机端 Agent 执行的测试指导书。测试对象是安装在安卓手机上的
> 「编制生成器」App（包名 `com.orbat.orbat_core`）。
> Agent 可通过 adb 或本机 UI 自动化能力操控手机完成下列用例。

---

## 一、测试环境与前置条件

| 项 | 要求 |
|---|---|
| 被测应用 | com.orbat.orbat_core（debug 签名，版本 0.3.5-beta 或更高） |
| 测试数据 | `/sdcard/orbat_test.json`（已推送；如缺失可从电脑端 `版本/v0.3.5-beta/模式三测试_v0.3.5/orbat_test.json` 重新 push） |
| 网络 | 需可访问 spatialillusions.com（出图） |
| 操控能力 | adb（input tap / screencap / uiautomator dump）或等效 UI 自动化 |
| 模式要求 | 应用已选「模式三 · Agent 插件」（无需 API Key 的用例为主） |

## 二、应用界面结构速查（v0.3.5-beta 安卓版）

- **顶栏**：`生成`（主按钮）、`出图`（主按钮）、`⋮更多`（选择图片/打开编制JSON/API用量/API对话/教程/环境自检/重置）、主题切换、设置
- **分页条**（AppBar 下）：`资料` / `编制树` / `预览` 三段切换
- **资料页**：`资料为主` / `纯文本` 模式切换；文本输入框；`全中文输出` 勾选
- **编制树页**：子 Tab `结构` / `JSON 编辑` / `批量`；右侧校验、导出图标按钮
- **预览页**：产物勾选（JSON/PNG/SVG）、白底开关、导出/复制按钮；输出目录行；出图进度面板；底部运行日志
- **设置对话框**：工作模式 / API Key / 识图模型 / 界面语言 / 日志与诊断（安卓端无渲染脚本输入框）

## 三、adb 操控速查

```bash
# 屏幕尺寸（用于坐标换算；本机 1080x2400，dpr≈2.75，逻辑宽约 393dp）
adb shell wm size

# 截屏并回传
adb shell screencap -p /sdcard/shot.png && adb pull /sdcard/shot.png

# 读取控件树（判断按钮文本与 bounds 坐标；Flutter 文本在 content-desc/text 中可能为空，
# 建议以截屏 OCR/视觉判断为主，控件树坐标为辅）
adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml

# 点击 / 滑动 / 返回
adb shell input tap <x> <y>
adb shell input swipe <x1> <y1> <x2> <y2> <时长ms>
adb shell input keyevent KEYCODE_BACK

# 启动 / 强停 / 安装
adb shell am start -n com.orbat.orbat_core/.MainActivity
adb shell am force-stop com.orbat.orbat_core
adb install -r <apk路径>        # MIUI 会弹确认框，需要人工点允许

# 查看产物目录（输出存档）
adb shell run-as com.orbat.orbat_core ls -R files 输出文件存档 2>/dev/null
adb shell ls -R /storage/emulated/0/Android/data/com.orbat.orbat_core/files 2>/dev/null
```

**坐标自适应**：不要硬编码本文示例坐标；每次先 `wm size` 换算，或用控件树 bounds 中心点点击。

## 四、测试用例清单

### T1 启动与首启流程（P0）
1. `force-stop` 后冷启动应用
2. 预期：3 秒内出现主界面（若首次启动则先语言选择 → 模式选择）
3. 模式选择对话框中：**模式二应显示"安卓暂不支持"且不可选中**（灰色）
4. 选模式三后进入主界面
- ✅ 通过标准：无崩溃、无黄黑条纹、模式二禁用

### T2 导入 JSON + 校验（P0）
1. 顶栏 `⋮更多` → `打开编制 JSON`
2. 系统文件选择器中进入内部存储根目录，选 `orbat_test.json`
3. 切到 `编制树` 分页 → 子 Tab `JSON 编辑` 查看内容
4. 点校验（图标按钮）
- ✅ 通过标准：25 节点、depth 4、红牌 0、警告 ≤2（直属下属 11 个 / 层级 4 为已知软警告）
- 记录：校验结果文案原文

### T3 出图全流程（P0，核心用例）
1. 顶栏点 `出图`
2. 预期弹出渲染页：全屏 WebView 加载 spatialillusions.com，顶部有进度日志滚动
3. 等待完成（15~60 秒；超时上限 5 分钟）
4. 完成后自动回到主界面并跳到 `预览` 分页
- ✅ 通过标准：预览页显示编制图 PNG；日志含 `PNG_FILE` 与 `[stage] 完成`
- 失败时记录：预览页日志区最后 6 行原文 + 截图
- 产物核验：输出目录（预览页第二行显示路径）下应生成 `2026-XX-XX_第5合成师.png`（可用 adb ls 验证）

### T4 设置对话框（P1）
1. 顶栏齿轮 → 设置
2. 逐屏查看：对话框内容**可滚动**（限高 72% 屏高），无黄黑条纹
3. helperText 长句（工作模式说明）**换行显示**，无 `RIGHT OVERFLOWED`
4. 安卓端**不出现**"渲染脚本 render_orbat.js"输入框
5. 点保存 → 无崩溃
- ✅ 通过标准：以上 5 项全部满足

### T5 环境自检（P1）
1. `⋮更多` → `环境自检`
2. 预期项目：Node.js / 浏览器 / 渲染脚本 三项显示"安卓端不需要/内置 WebView"；API Key 可为空提示；**输出目录可写 = 通过**；DeepSeek 接口连通（可选）；渲染站点连通（可选）
3. 出图冒烟显示"安卓端跳过"
- ✅ 通过标准：非可选项全绿（API Key 在模式三下不强制）
- ⚠️ 已知问题观察：若"输出目录可写"失败，记录输出目录路径原文

### T6 分页与溢出回归（P1）
逐一切换 `资料` → `编制树` → `预览`，并在每页：
- 观察有无黄黑斜条纹（RIGHT/BOTTOM OVERFLOWED），记录像素数与位置
- `编制树` 顶部 Tab 行右侧不得溢出；底部状态栏文字不得被手势条遮挡
- ✅ 通过标准：零条纹

### T7 界面语言切换（P2）
1. 设置 → 界面语言 → English
2. 检查顶栏/分页条/设置页文案变英文
3. 切回中文
- ✅ 通过标准：主要控件文案切换、无布局崩坏

### T8 重置（P2）
1. `⋮更多` → `重置`
2. 确认应用回到初始空状态
- ✅ 通过标准：无崩溃，空状态提示正常

## 五、结果记录格式

每个用例按以下 JSON 结构输出，最终汇总为一份报告：

```json
{
  "case": "T3",
  "title": "出图全流程",
  "result": "PASS | FAIL | BLOCKED",
  "screenshots": ["/sdcard/t3_step2.png"],
  "logExcerpt": "预览页日志最后几行原文",
  "notes": "任何异常、条纹像素数、崩溃堆栈"
}
```

汇总报告包含：环境（机型/系统版本/应用版本号 lastUpdateTime）、用例通过率、
全部 FAIL 项的截图与日志、与本文预期不符的行为清单。

## 六、故障排查

| 现象 | 处理 |
|---|---|
| adb install 报 INSTALL_FAILED_USER_RESTRICTED | 手机端点允许；或在开发者选项确认"USB 安装"已开 |
| 出图卡在"等待站点初始化" | 确认手机浏览器能打开 spatialillusions.com |
| 出图报"PNG 光栅化失败" | 记录 `window.__orbatErr` 原文（预览页日志可见） |
| 应用崩溃 | `adb logcat -d \| grep -iE "flutter\|FATAL"` 抓取后附报告 |
| 找不到产物 | 预览页第二行"输出目录"显示实际路径，用 adb ls 验证 |

## 七、测试边界（本期不做）

- 模式一/模式二（安卓端模式二已禁用；模式一需 API Key，可另测）
- 安卓单元测试 / 性能测试
- 平板横屏布局
