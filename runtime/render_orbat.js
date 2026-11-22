// 把编制 JSON 导入 spatialillusions.com 的 Battle Staff Tools，导出整树 SVG + PNG
// 用法: node render_orbat.js <input.json> <outBasename>
const fs = require("fs");
const os = require("os");
const path = require("path");
const { launch, connect, sleep, waitFor } = require("./cdp");

// ---------- 运行时守卫：node 主版本必须 ≥ 24 ----------
// managed node v22.22.2 跑本脚本会**无界挂起**：画布已渲染完，但 `SVG_STAT` 之后再无输出，
// 进程永不退出，只能被外层 timeout 杀掉（4 格对照矩阵见 `_tools/出图排错与防误诊.md` §3.6、§8）。
// 这里快速失败，免得又演变成"静默挂满 timeout → 误诊成站点/数据坏了"。
if (Number(process.versions.node.split(".")[0]) < 24) {
  console.error("FATAL: 出图必须用 node ≥ 24，当前是 v" + process.versions.node);
  console.error('  请改用："C:\\Program Files\\nodejs\\node.exe" _tools\\render_orbat.js <json> <base>');
  process.exit(2);
}

const inputJson = path.resolve(process.argv[2]);
const base = path.resolve(process.argv[3]);
const SCALE = Number(process.env.SCALE || 2);
// 白色背景开关：true=白底 PNG（默认），false=透明底 PNG（方便叠自定义背景图）
// 只影响 PNG 截图；SVG 始终保持透明（矢量文件背景由使用方决定）
const WHITE_BG = (process.env.ORBAT_WHITE_BG || '1') !== '0';
// 注入到页面 eval 里的带引号字面量（避免模板字符串双引号被吞）
const BG_LITERAL = WHITE_BG ? "'#ffffff'" : "'transparent'";
console.log('[config] PNG 背景: ' + (WHITE_BG ? '白色' : '透明'));
console.log('[config] BG_LITERAL = ' + BG_LITERAL);

// 删掉 Chrome 的临时 profile 目录（每套约 15MB）。Windows 上 Chrome 刚被杀时句柄可能还没释放，
// 所以重试几次；实在删不掉只警告、不影响出图。
// （2026-10-16 实测：不清理会无限堆积——攒了 191 个目录 = 2.87 GB。）
async function rmTempProfile(dir) {
  for (let i = 0; i < 10; i++) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
      return;
    } catch (e) {
      await sleep(300);
    }
  }
  console.error("WARN: 临时 profile 没删掉（不影响出图）：" + dir);
}

let activeChrome = null;
let activeCdp = null;
let activeProfile = null;
let cleanupPromise = null;
let shutdownRequested = false;

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    if (activeCdp) {
      try { activeCdp.close(); } catch (_) {}
      activeCdp = null;
    }
    const chrome = activeChrome;
    const child = chrome?.process;
    if (child && child.exitCode === null && child.signalCode === null) {
      // Use the browser-level CDP command first; killing only the browser parent on
      // Windows can leave renderer subprocesses alive and keep profile files locked.
      if (chrome.browserWebSocketUrl) {
        const browserCdp = new (require("./cdp").CDP)(chrome.browserWebSocketUrl);
        try {
          await browserCdp.open();
          await browserCdp.send("Browser.close", {}, 3000);
        } catch (_) {
        } finally {
          browserCdp.close();
        }
      }
      if (child.exitCode === null && child.signalCode === null) {
        await new Promise((resolve) => {
          const timer = setTimeout(() => {
            try { child.kill("SIGKILL"); } catch (_) {}
            resolve();
          }, 5000);
          child.once("exit", () => {
            clearTimeout(timer);
            resolve();
          });
        });
      }
    }
    activeChrome = null;
    if (activeProfile) {
      await rmTempProfile(activeProfile);
      activeProfile = null;
    }
  })();
  return cleanupPromise;
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (data) => {
  if (!data.includes("ORBAT_SHUTDOWN")) return;
  shutdownRequested = true;
  cleanup().finally(() => process.exit(0));
});
// Keep a shutdown command available while rendering, but don't keep an otherwise
// completed Node process alive solely because Dart still owns the stdin pipe.
if (typeof process.stdin.unref === "function") process.stdin.unref();

async function main() {
  // 优先用调用方指定的可写目录（Dart 侧已探测过权限）；否则退回系统临时目录。
  const WORK_DIR = process.env.ORBAT_WORK_DIR || os.tmpdir();
  fs.mkdirSync(WORK_DIR, { recursive: true });
  activeProfile = fs.mkdtempSync(path.join(WORK_DIR, "orbat-render-"));
  console.log("[stage] 启动浏览器");
  activeChrome = await launch(activeProfile, [], (process) => {
    // Track the process before CDP startup completes so a timeout can stop it too.
    activeChrome = { process };
  });
  try {
    console.log("[stage] 连接调试通道");
    activeCdp = await connect(activeChrome);
    const cdp = activeCdp;

    // ---- 请求拦截 / polyfill：已于 2026-10-16 **整段删除，不留开关** ----
    // 这里曾有一段「字体请求 failRequest + Object.prototype.removeShadowUnits 补丁」，
    // 依据的是「站点包把 removeShadowUnits 弄丢了 + 字体 CDN 被挡」的误诊，实测全部不成立：
    //   ① 站点包 5MB 内联 JS 里没有 @font-face / webfont CDN 引用，字体理论不成立；
    //   ② removeShadowUnits 在包里 offset 1773464 有原生定义，报错是因为调用点上的 r
    //      不是该类实例；补 no-op 只把报错推迟到紧邻的下一行 r.computeBaseSize；
    //   ③ 该报错对导出无害：单通道成功运行时也照样打印（node v24 实测 13.5s rc=0）。
    // 而 `Fetch.enable` 全量拦截有确凿的副作用：每个网络请求都多一轮 CDP 往返，让页面初始化更容易输竞态。
    //   （"并发下必挂"只有过一次 2/2 挂起的观测，当时批量夹具尚未被质疑——见手册 §3.7——不足以断言机制。）
    // 结论：零收益 + 开关本身就是下一次误触发的入口 ⇒ **删代码，而不是加开关**
    //   （`ORBAT_CDP_HOOKS` 这类开关迟早会被打开一次）。详见 _tools/出图排错与防误诊.md §3.2。
    // 另外：`_tools/cdp.js` 已注册 onclose + 90s 兜底超时，CDP 响应丢失会**明确报错**而不是静默挂死。

    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 2400, height: 1400, deviceScaleFactor: 1, mobile: false,
    });
    console.log("[stage] 打开渲染站点");
    await cdp.send("Page.navigate", { url: "https://spatialillusions.com/unitgenerator" });
    console.log("[stage] 等待站点初始化");
    await waitFor(async () => !!(await cdp.eval("!!document.querySelector('#openOrbat')")), 120000, 1000, "站点初始化");
    await sleep(4000);

    // ---- 导入 JSON ----
    // 注意：#orbat-svg 这个元素在页面初始化后就已经存在（是编辑器画布），
    // 所以「元素存在」不能当作「导入成功」。必须等到 SVG 里真的出现本图根节点的名字。
    const rootName = (() => {
      try { return JSON.parse(fs.readFileSync(inputJson, "utf8")).options.uniqueDesignation || ""; }
      catch (e) { return ""; }
    })();

    const waitRendered = () => waitFor(async () => !!(await cdp.eval(
      "(() => { const s = document.querySelector('#orbat-svg');" +
      " if (!s || !s.querySelectorAll('*').length) return false;" +
      " const want = " + JSON.stringify(rootName) + ";" +
      " return !want || s.textContent.includes(want); })()"
    )), 45000, 500, "画布渲染");

    const importOnce = async () => {
      const doc = await cdp.send("DOM.getDocument", { depth: -1 });
      const q = await cdp.send("DOM.querySelector", { nodeId: doc.root.nodeId, selector: "#openOrbat" });
      if (!q || !q.nodeId) throw new Error("页面上找不到 #openOrbat（站点还没初始化完）");
      await cdp.send("DOM.setFileInputFiles", { files: [inputJson], nodeId: q.nodeId });
      await waitRendered();
    };

    let imported = false;
    for (let attempt = 1; attempt <= 2 && !imported; attempt++) {
      console.log(`[stage] 导入编制数据（第 ${attempt} 次）`);
      try { await importOnce(); imported = true; }
      catch (e) {
        console.log("[import] 第 " + attempt + " 次导入未生效：" + e.message);
        await sleep(3000);
      }
    }
    if (!imported) throw new Error("导入编制 JSON 后 #orbat-svg 里没有出现本图内容（站点未就绪）");
    await sleep(1500);

    console.log("[stage] 统计渲染结果");

    // ---- 记录渲染结果规模 ----
    const stat = await cdp.eval(`(() => {
      const svg = document.querySelector('#orbat-svg');
      if (!svg) return { err: 'no #orbat-svg' };
      return {
        elements: svg.querySelectorAll('*').length,
        texts: Array.from(svg.querySelectorAll('text')).map(t => (t.textContent||'').trim()).filter(Boolean).length,
        viewBox: svg.getAttribute('viewBox'),
      };
    })()`);
    console.log("SVG_STAT " + JSON.stringify(stat));

    // ---- 抠出独立 SVG（保留页面字体环境）----
    const got = await cdp.eval(`(() => {
      const svg = document.querySelector('#orbat-svg');
      const vb = (svg.getAttribute('viewBox') || '0 0 100 100').trim().split(/[\\s,]+/).map(Number);
      const src = svg.outerHTML;
      document.body.innerHTML = '';
      document.body.style.margin = '0';
      const bg = ${BG_LITERAL};
      document.body.style.background = bg;
      document.documentElement.style.background = bg;
      const holder = document.createElement('div');
      holder.style.cssText = 'position:absolute;left:0;top:0;background:' + bg + ';';
      holder.innerHTML = src;
      document.body.appendChild(holder);
      const s2 = holder.querySelector('svg');
      s2.setAttribute('width', vb[2]);
      s2.setAttribute('height', vb[3]);
      s2.style.width = vb[2] + 'px';
      s2.style.height = vb[3] + 'px';
      s2.style.display = 'block';
      return { vb, len: src.length };
    })()`);
    console.log("SVG_META " + JSON.stringify(got));
    if (got.len > 100) {
      console.log("[stage] 导出 SVG");
      const svgText = await cdp.eval(`document.querySelector('body svg').outerHTML`);
      fs.writeFileSync(base + ".svg", svgText, "utf8");
      console.log("SVG_FILE " + (base + ".svg"));
    }

    const w = Math.ceil(got.vb[2]);
    const h = Math.ceil(got.vb[3]);
    console.log("[stage] 导出 PNG");

    // 用 canvas 把 SVG 光栅化为 PNG。
    // 之前用 Page.captureScreenshot 截页面，Chrome 在 captureBeyondViewport 下会强制白底，
    // omitBackground 无效；canvas 方案天然支持透明，且不依赖页面 body 背景。
    const pngDataUrl = await cdp.eval(`(async () => {
      const svgEl = document.querySelector('body svg');
      if (!svgEl) throw new Error('no svg for rasterize');
      const vb = (svgEl.getAttribute('viewBox') || '0 0 ${w} ${h}').trim().split(/[\\s,]+/).map(Number);
      const sx = vb[0] || 0, sy = vb[1] || 0, sw = vb[2] || ${w}, sh = vb[3] || ${h};

      // 复制一份 SVG，去掉 width/height 的 px 限制，用 viewBox 控制尺寸
      const clone = svgEl.cloneNode(true);
      clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
      clone.setAttribute('width', sw);
      clone.setAttribute('height', sh);
      clone.removeAttribute('style');
      const xml = new XMLSerializer().serializeToString(clone);
      const blob = new Blob([xml], {type: 'image/svg+xml;charset=utf-8'});
      const url = URL.createObjectURL(blob);

      const canvas = document.createElement('canvas');
      canvas.width = Math.ceil(sw * ${SCALE});
      canvas.height = Math.ceil(sh * ${SCALE});
      const ctx = canvas.getContext('2d');
      // 透明底时什么都不画；白底时填白
      ${WHITE_BG ? "ctx.fillStyle = '#ffffff'; ctx.fillRect(0,0,canvas.width,canvas.height);" : ""}

      const img = new Image();
      await new Promise((resolve, reject) => {
        img.onload = resolve;
        img.onerror = (e) => reject(new Error('svg image load failed: ' + e));
        img.src = url;
      });
      // viewBox 可能有负 x（如 -50），绘制时按 viewBox 原点偏移
      ctx.drawImage(img, -sx * ${SCALE}, -sy * ${SCALE}, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      return canvas.toDataURL('image/png');
    })()`);

    const b64 = pngDataUrl.split(',')[1];
    fs.writeFileSync(base + ".png", Buffer.from(b64, "base64"));
    console.log("PNG_FILE " + (base + ".png") + " " + w + "x" + h + " @" + SCALE + "x = " + (w * SCALE) + "x" + (h * SCALE));

    console.log("[stage] 完成");
  } finally {
    await cleanup();
  }
}

main().catch(async (e) => {
  if (shutdownRequested) return;
  console.error("FAILED:", e.message);
  await cleanup();
  process.exit(1);
});
