import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { launch, connect, sleep, waitFor } = require('./cdp.js');
const os = await import('os');
const path = await import('path');
const fs = await import('fs');

const PORT = 9421;
const userData = path.join(os.tmpdir(), 'orbat-probe-bg-' + Date.now());
const chrome = await launch(PORT, userData, []);
let cdp;
try {
  cdp = await connect(PORT);
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 2400, height: 1400, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Page.navigate', { url: 'https://spatialillusions.com/unitgenerator' });
  await waitFor(async () => !!(await cdp.eval('!!document.querySelector("#openOrbat")')), 120000, 1000, '初始化');
  await sleep(4000);

  // 列出所有 input/select/button，标出含 bg/background/white/transparen/color 字样的
  const controls = await cdp.eval(`(() => {
    const out = [];
    document.querySelectorAll('input,select,button,label,[role=checkbox],[role=switch]').forEach(el => {
      const id = el.id || '';
      const name = el.name || '';
      const type = el.type || '';
      const val = (el.value || '').toString().slice(0,60);
      const txt = (el.textContent || '').trim().slice(0,80);
      const title = el.title || '';
      const cls = (el.className || '').toString().slice(0,60);
      const hay = (id+' '+name+' '+type+' '+val+' '+txt+' '+title+' '+cls).toLowerCase();
      const hit = /bg|background|white|transparen|color|theme|export|png|svg|image/i.test(hay);
      out.push({tag:el.tagName, id, name, type, val, txt, title, cls, hit});
    });
    return out;
  })()`);

  console.log('=== 疑似背景/导出相关控件 ===');
  controls.filter(c => c.hit).forEach(c => console.log(JSON.stringify(c)));
  console.log('\n=== 全部控件数:', controls.length, '===');
  console.log('=== 控件里含 bg/white/transparen 的 ===');
  console.log(JSON.stringify(controls.filter(c => /bg|background|white|transparen/i.test((c.id+' '+c.name+' '+c.val+' '+c.txt+' '+c.title).toLowerCase())), null, 2));

  // 看看有没有导出面板/按钮被隐藏
  const panels = await cdp.eval(`(() => {
    const out=[];
    document.querySelectorAll('[id]').forEach(el=>{
      const h=(el.id+' '+(el.className||'')).toLowerCase();
      if(/export|save|download|png|svg|option|setting|config/i.test(h)){
        const st=getComputedStyle(el);
        out.push({id:el.id, cls:(el.className||'').toString().slice(0,60), display:st.display, vis:st.visibility, txt:(el.textContent||'').trim().slice(0,60)});
      }
    });
    return out;
  })()`);
  console.log('\n=== 导出/设置相关面板 ===');
  panels.slice(0,30).forEach(p=>console.log(JSON.stringify(p)));

} finally {
  if (cdp) cdp.close();
  chrome.kill();
  try { fs.rmSync(userData, {recursive:true, force:true}); } catch {}
}
