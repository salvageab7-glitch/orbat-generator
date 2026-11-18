import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { launch, connect, sleep, waitFor } = require('./cdp.js');
const os = await import('os'); const path = await import('path'); const fs = await import('fs');
const PORT = 9424;
const userData = path.join(os.tmpdir(), 'orbat-probe-bg4-' + Date.now());
const chrome = await launch(PORT, userData, []);
let cdp;
try {
  cdp = await connect(PORT);
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 2400, height: 1400, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Page.navigate', { url: 'https://spatialillusions.com/unitgenerator' });
  await waitFor(async () => !!(await cdp.eval('!!document.querySelector("#openOrbat")')), 120000, 1000, 'init');
  await sleep(3000);

  // 导入测试 JSON（用现成的）
  const jsonPath = path.resolve('../test/_cl2.json');
  const doc = await cdp.send('DOM.getDocument', {depth:-1});
  const q = await cdp.send('DOM.querySelector', {nodeId:doc.root.nodeId, selector:'#openOrbat'});
  await cdp.send('DOM.setFileInputFiles', {files:[jsonPath], nodeId:q.nodeId});
  await waitFor(async () => !!(await cdp.eval(`(() => {const s=document.querySelector('#orbat-svg'); return s && s.querySelectorAll('*').length>10;})()`)), 45000, 500, 'render');
  await sleep(1500);
  console.log('已导入 JSON');

  // 检查 PNG 下载链接的 href/onclick
  const link = await cdp.eval(`(() => {
    const a=Array.from(document.querySelectorAll('a')).find(x=>x.title==='Download as PNG');
    if(!a) return null;
    return {href:a.getAttribute('href')||'', onclick:a.onclick?a.onclick.toString().slice(0,400):'none', outer:a.outerHTML.slice(0,300)};
  })()`);
  console.log('PNG下载链接:', JSON.stringify(link,null,2));

  // 关掉白色背景 → 点击下载
  await cdp.eval(`(() => {const c=document.querySelector('#pngBackground'); if(c.checked) c.click();})()`);
  await sleep(800);
  console.log('已取消勾选 White PNG background');

  // CDP 允许下载到指定目录
  const dlDir = path.resolve('../test/_bg_dl');
  fs.mkdirSync(dlDir, {recursive:true});
  await cdp.send('Browser.setDownloadBehavior', {behavior:'allow', downloadPath:dlDir, eventsEnabled:true});
  await cdp.eval(`(() => {const a=Array.from(document.querySelectorAll('a')).find(x=>x.title==='Download as PNG'); if(a) a.click();})()`);
  await sleep(4000);
  const files = fs.readdirSync(dlDir).map(f=>({name:f, size:fs.statSync(path.join(dlDir,f)).size}));
  console.log('下载文件:', JSON.stringify(files));

  // 分析下载的图片 alpha 通道
  for (const f of files) {
    if (!f.name.toLowerCase().endsWith('.png')) continue;
    const buf = fs.readFileSync(path.join(dlDir, f.name));
    // PNG IHDR: width@16 height@20 bitdepth@24 colortype@25
    const w=buf.readUInt32BE(16), h=buf.readUInt32BE(20), bd=buf[24], ct=buf[25];
    console.log(`PNG ${f.name}: ${w}x${h} bitDepth=${bd} colorType=${ct} ${ct===6?'(RGBA 有alpha)':ct===2?'(RGB 无alpha)':''}`);
    // 检查左上角像素是否透明（简单看 IDAT 解压太复杂，先看 colorType）
  }

} finally {
  if (cdp) cdp.close();
  chrome.kill();
  try { fs.rmSync(userData, {recursive:true, force:true}); } catch {}
}
