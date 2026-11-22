// Minimal Chrome DevTools Protocol helper (no npm dependencies).
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

// ---- 浏览器解析：环境变量 → orbat.config.json → 注册表/常见路径 → PATH ----
// 原实现把路径写死成 C:\Program Files\Google\Chrome\Application\chrome.exe，
// 换机器（Chrome 装到别处、或只有 Edge）就直接起不来。
// launch() 用的 --headless=new / --remote-debugging-port / --user-data-dir 全是
// Chromium 通用开关，Edge / Brave 同样认 —— 所以它们是同源替代，不是将就。
function firstExisting(list) {
  for (const p of list) {
    if (!p) continue;
    try { if (fs.existsSync(p)) return p; } catch (e) {}
  }
  return null;
}

function fromConfig() {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "orbat.config.json"), "utf8"));
    return cfg.browser || null;
  } catch (e) { return null; }
}

function fromKnownDirs() {
  const roots = [
    process.env["ProgramFiles"],
    process.env["ProgramFiles(x86)"],
    process.env["LOCALAPPDATA"],
    "C:\\Program Files",
    "C:\\Program Files (x86)",
  ].filter(Boolean);
  const rels = [
    "Google\\Chrome\\Application\\chrome.exe",
    "Microsoft\\Edge\\Application\\msedge.exe",
    "BraveSoftware\\Brave-Browser\\Application\\brave.exe",
    "Chromium\\Application\\chrome.exe",
  ];
  const out = [];
  for (const r of rels) for (const base of roots) out.push(path.join(base, r));
  return out;
}

function fromPath() {
  const dirs = (process.env.PATH || "").split(path.delimiter).filter(Boolean);
  const names = ["chrome.exe", "msedge.exe", "brave.exe", "chromium.exe"];
  const out = [];
  for (const n of names) for (const d of dirs) out.push(path.join(d, n));
  return out;
}

function resolveBrowser() {
  const hit =
    firstExisting([process.env.ORBAT_CHROME]) ||
    firstExisting([fromConfig()]) ||
    firstExisting(fromKnownDirs()) ||
    firstExisting(fromPath());
  if (hit) return hit;
  throw new Error(
    "未找到 Chromium 系浏览器（Chrome / Edge / Brave / Chromium 都没有）。\n" +
    "  1) 装 Chrome 或 Edge（Windows 自带 Edge 通常已有）；或\n" +
    "  2) 设环境变量 ORBAT_CHROME=<chrome.exe 或 msedge.exe 的完整路径>。"
  );
}

const CHROME = resolveBrowser();

// 单条 CDP 请求的兜底超时：默认 90s。正常出图全程 13–20 s，截图也只需几秒。
// 它存在的唯一目的，是把「响应丢了」从**无界挂起**变成**明确报错**——2026-10-16 那次
// 11 套全 FAIL 之所以表现成"静默卡死、只能被外层 timeout 掐掉"，就是因为没有这层兜底：
// waitFor 自己虽有 45s/120s 超时，但它 await 的 cdp.eval 永不 settle 时，waitFor 根本轮不到。
// 需要更宽松可用环境变量 ORBAT_CDP_SEND_TIMEOUT 调大（毫秒）。
const SEND_TIMEOUT = Number(process.env.ORBAT_CDP_SEND_TIMEOUT || 90000);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// timeoutMs 到点仍未满足条件就抛错；label 非空时每 5 秒打一次心跳，
// 目的是让上层（GUI）能显示"还在等什么、等了多久"，而不是整段静默。
async function waitFor(check, timeoutMs, intervalMs = 500, label = "") {
  const start = Date.now();
  let lastReport = 0;
  while (Date.now() - start < timeoutMs) {
    try {
      const v = await check();
      if (v) {
        if (label) {
          console.log(`[wait] ${label} 就绪 (${((Date.now() - start) / 1000).toFixed(1)}s)`);
        }
        return v;
      }
    } catch (e) {}
    const elapsed = Date.now() - start;
    if (label && elapsed - lastReport >= 5000) {
      lastReport = elapsed;
      console.log(`[wait] ${label} 等待中 ${Math.round(elapsed / 1000)}s / ${Math.round(timeoutMs / 1000)}s`);
    }
    await sleep(intervalMs);
  }
  throw new Error(`waitFor timeout after ${timeoutMs}ms${label ? " (" + label + ")" : ""}`);
}

class CDP {
  constructor(wsUrl, logName) {
    this.ws = new global.WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.logName = logName || null;
  }
  async open() {
    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = (e) => reject(new Error("WS error: " + (e.message || "connect failed")));
    });
    // 连接掉线时必须让挂起的 send() 失败。原实现没注册 onclose，掉线时那些 Promise
    // **永不 settle** ⇒ 无界挂起（本次事故的理论挂起点）。现在一律以明确错误结束。
    this.ws.onclose = () => {
      const err = new Error("CDP 连接已关闭：未完成的请求全部失败");
      for (const { reject } of this.pending.values()) reject(err);
      this.pending.clear();
    };
    this.ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) reject(new Error(`${m.error.message} (${JSON.stringify(m.error.data || "")})`));
        else resolve(m.result);
      } else if (m.method === "Page.javascriptDialogOpening") {
        this.send("Page.handleJavaScriptDialog", { accept: true }).catch(() => {});
      } else if (m.method === "Runtime.exceptionThrown") {
        const d = m.params.exceptionDetails;
        console.log("[pageerror]", String((d.exception && (d.exception.description || d.exception.value)) || d.text).slice(0, 400));
      } else if (m.method === "Runtime.consoleAPICalled") {
        const a = (m.params.args || []).map((x) => x.value ?? x.description ?? x.type).join(" ");
        if (m.params.type === "error" || m.params.type === "warning") console.log("[" + m.params.type + "]", String(a).slice(0, 300));
      }
    };
  }
  send(method, params = {}, timeoutMs = SEND_TIMEOUT) {
    const id = ++this.id;
    const p = new Promise((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
            if (this.pending.delete(id)) {
              reject(new Error(`CDP 请求超时 ${timeoutMs}ms：${method}（响应丢失，不再无限等待）`));
            }
          }, timeoutMs)
        : null;
      this.pending.set(id, {
        resolve: (v) => { if (timer) clearTimeout(timer); resolve(v); },
        reject: (e) => { if (timer) clearTimeout(timer); reject(e); },
      });
    });
    // 标记为已处理，避免"没人 await 的 fire-and-forget 请求"在超时/掉线时
    // 触发未处理拒绝把整个进程打崩；调用方拿到的仍是原始 Promise，拒绝照旧可见。
    p.catch(() => {});
    this.ws.send(JSON.stringify({ id, method, params }));
    return p;
  }
  async eval(expression) {
    const r = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    });
    if (r.exceptionDetails) {
      throw new Error("eval error: " + JSON.stringify(r.exceptionDetails).slice(0, 500));
    }
    return r.result ? r.result.value : undefined;
  }
  close() {
    try { this.ws.close(); } catch (e) {}
  }
}

async function launch(userData, extraArgs = [], onSpawned = null) {
  fs.mkdirSync(userData, { recursive: true });
  const logPath = path.join(
    process.env.ORBAT_WORK_DIR || os.tmpdir(),
    "browser-" + path.basename(userData) + ".log"
  );
  const out = fs.openSync(logPath, "w");
  try { console.log(`browser: ${path.basename(CHROME)}  (${CHROME})`); } catch (_) {}
  const proc = spawn(
    CHROME,
    [
      "--headless=new",
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-breakpad",
      "--disable-crash-reporter",
      "--disable-features=Crashpad",
      "--window-size=2400,1400",
      "--remote-debugging-address=127.0.0.1",
      // Port 0 asks Chromium to select an ephemeral port and record it under this
      // process-specific profile, avoiding fixed-port collisions and stale CDP reuse.
      "--remote-debugging-port=0",
      `--user-data-dir=${userData}`,
      ...extraArgs,
      "about:blank",
    ],
    { stdio: ["ignore", out, out] }
  );
  if (typeof onSpawned === "function") onSpawned(proc);
  try {
    let endpoint;
    await waitFor(async () => {
      try {
        if (proc.exitCode !== null || proc.signalCode !== null) return false;
        const activePortPath = path.join(userData, "DevToolsActivePort");
        const lines = fs.readFileSync(activePortPath, "utf8").trim().split(/\r?\n/);
        const port = Number(lines[0]);
        const browserPath = lines[1];
        if (!Number.isInteger(port) || port < 1 || port > 65535 ||
            !browserPath || !browserPath.startsWith("/devtools/browser/")) return false;
        const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
          signal: AbortSignal.timeout(2000),
        });
        if (!response.ok) return false;
        const version = await response.json();
        const ws = new URL(version.webSocketDebuggerUrl);
        if (Number(ws.port) !== port || ws.pathname !== browserPath) return false;
        endpoint = { port, browserWebSocketUrl: version.webSocketDebuggerUrl };
        return true;
      } catch (_) {
        return false;
      }
    }, 40000, 500, "本次浏览器调试端口");
    console.log("[stage] 浏览器就绪");
    return { process: proc, ...endpoint };
  } catch (e) {
    try { console.log("--- browser log ---\n" + fs.readFileSync(logPath, "utf8").slice(-2000)); } catch (_) {}
    try { proc.kill(); } catch (_) {}
    throw e;
  } finally {
    try { fs.closeSync(out); } catch (_) {}
  }
}

async function connect(chrome) {
  if (!chrome || chrome.process.exitCode !== null || chrome.process.signalCode !== null) {
    throw new Error("本次启动的 Chromium 进程已退出");
  }
  const versionResponse = await fetch(`http://127.0.0.1:${chrome.port}/json/version`, {
    signal: AbortSignal.timeout(5000),
  });
  if (!versionResponse.ok) throw new Error("无法读取本次 Chromium 的 CDP 信息");
  const version = await versionResponse.json();
  if (version.webSocketDebuggerUrl !== chrome.browserWebSocketUrl) {
    throw new Error("CDP 端点与本次启动的 Chromium 不匹配");
  }
  const targetsResponse = await fetch(`http://127.0.0.1:${chrome.port}/json/list`, {
    signal: AbortSignal.timeout(5000),
  });
  if (!targetsResponse.ok) throw new Error("无法读取 Chromium 页面目标");
  const targets = await targetsResponse.json();
  const page = targets.find((t) => t.type === "page" && t.url === "about:blank");
  if (!page || !page.webSocketDebuggerUrl) {
    throw new Error("本次 Chromium 未提供初始页面 CDP 目标");
  }
  const cdp = new CDP(page.webSocketDebuggerUrl);
  await cdp.open();
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("DOM.enable");
  return cdp;
}

module.exports = { CHROME, CDP, sleep, waitFor, launch, connect };
