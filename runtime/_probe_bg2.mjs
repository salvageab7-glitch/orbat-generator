import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { launch, connect, sleep, waitFor } = require('./cdp.js');
const os = await import('os'); const path = await import('path'); const fs = await import('fs');
const PORT = 9422;
const userData = path.join(os.tmpdir(), 'orbat-probe-bg2-' + Date.now());
const chrome = await launch(PORT, userData, []);
let cdp;
try {
  cdp = await connect(PORT);
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 2400, height: 1400, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Page.navigate', { url: 'https://spatialillusions.com/unitgenerator' });
  await waitFor(async () => !!(await cdp.eval('!!document.querySelector("#openOrbat")')), 120000, 1000, 'init');
  await sleep(3000);

  // 初始状态
  const init = await cdp.eval(`(() => {
    const c = document.querySelector('#pngBackground');
    const l = Array.from(document.querySelectorAll('label')).find(x=>x.textContent.includes('White PNG'));
    return {checked:c.checked, disabled:c.disabled, labelText:l?l.textContent.trim():'', labelFor:l?l.htmlFor:''};
  })()`);
  console.log('初始状态:', JSON.stringify(init));

  // 读取 checkbox 关联的全局变量/事件
  const info = await cdp.eval(`(() => {
    const c = document.querySelector('#pngBackground');
    return {
      outer: c.outerHTML.slice(0,200),
      parent: c.parentElement ? c.parentElement.outerHTML.slice(0,400) : '',
      hasOnChange: !!c.onchange,
    };
  })()`);
  console.log('控件信息:', JSON.stringify(info, null, 2));

  // 尝试用 CDP 点击（真实 click 事件）
  const before = await cdp.eval(`document.querySelector('#pngBackground').checked`);
  await cdp.eval(`document.querySelector('#pngBackground').click()`);
  await sleep(500);
  const after = await cdp.eval(`document.querySelector('#pngBackground').checked`);
  console.log('点击测试: before=' + before + ' after=' + after + ' 变化=' + (before!==after));

  // 再改回原状
  await cdp.eval(`document.querySelector('#pngBackground').click()`);

} finally {
  if (cdp) cdp.close();
  chrome.kill();
  try { fs.rmSync(userData, {recursive:true, force:true}); } catch {}
}
