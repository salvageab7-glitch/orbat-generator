import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { launch, connect, sleep, waitFor } = require('./cdp.js');
const os = await import('os'); const path = await import('path'); const fs = await import('fs');
const PORT = 9423;
const userData = path.join(os.tmpdir(), 'orbat-probe-bg3-' + Date.now());
const chrome = await launch(PORT, userData, []);
let cdp;
try {
  cdp = await connect(PORT);
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 2400, height: 1400, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Page.navigate', { url: 'https://spatialillusions.com/unitgenerator' });
  await waitFor(async () => !!(await cdp.eval('!!document.querySelector("#openOrbat")')), 120000, 1000, 'init');
  await sleep(3000);

  // 找网站自己的 PNG 导出按钮/函数
  const exports = await cdp.eval(`(() => {
    const out=[];
    document.querySelectorAll('button,a,[id]').forEach(el=>{
      const s=(el.id+' '+(el.textContent||'')+' '+(el.title||'')).toLowerCase();
      if(/png|download|save|export|image/i.test(s) && s.length<200){
        out.push({tag:el.tagName,id:el.id,txt:(el.textContent||'').trim().slice(0,40),title:el.title||''});
      }
    });
    return out.slice(0,25);
  })()`);
  console.log('导出相关元素:'); exports.forEach(e=>console.log(' ', JSON.stringify(e)));

  // 看 checkbox 的 onchange 函数源码
  const fn = await cdp.eval(`(() => {
    const c=document.querySelector('#pngBackground');
    const h=c.onchange;
    return h ? h.toString().slice(0,600) : 'null';
  })()`);
  console.log('\nonchange 源码:\n', fn);

  // 看 checkbox 变化时是否影响 svg 背景
  const svgBgBefore = await cdp.eval(`(() => {
    const s=document.querySelector('#orbat-svg');
    if(!s) return 'no svg';
    return {style:s.getAttribute('style')||'', bg:getComputedStyle(s).backgroundColor, child0: s.children[0] ? s.children[0].tagName : ''};
  })()`);
  console.log('\nSVG 背景(勾选前):', JSON.stringify(svgBgBefore));
  await cdp.eval(`document.querySelector('#pngBackground').click()`);
  await sleep(500);
  const svgBgAfter = await cdp.eval(`(() => {
    const s=document.querySelector('#orbat-svg');
    if(!s) return 'no svg';
    return {style:s.getAttribute('style')||'', bg:getComputedStyle(s).backgroundColor};
  })()`);
  console.log('SVG 背景(勾选后):', JSON.stringify(svgBgAfter));

} finally {
  if (cdp) cdp.close();
  chrome.kill();
  try { fs.rmSync(userData, {recursive:true, force:true}); } catch {}
}
