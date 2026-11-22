import assert from 'node:assert/strict';
import test from 'node:test';

function makeReact() {
  return {
    createElement(type, props, ...children) {
      return { type, props: props || {}, children: children.flat().filter((child) => child !== null && child !== undefined && child !== false) };
    },
    useCallback(callback) { return callback; },
    useEffect() {},
    useState(initial) { return [initial, () => {}]; },
    useSyncExternalStore(_subscribe, getSnapshot) { return getSnapshot(); },
  };
}

function collectText(node, output = []) {
  if (typeof node === 'string') output.push(node);
  else if (Array.isArray(node)) node.forEach((child) => collectText(child, output));
  else if (node && typeof node === 'object') collectText(node.children, output);
  return output;
}

test('Client registers a localized Settings section and renders the requested controls', async (t) => {
  let loaded;
  const previousWindow = globalThis.window;
  globalThis.window = {
    __ModuleLoader__: {
      load(module) { loaded = module; },
    },
  };
  t.after(() => {
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
  });

  await import('../client.js');
  assert.equal(loaded.id, '@local/orbat-agent/client');
  const react = makeReact();
  const client = loaded.factory((name) => {
    assert.equal(name, 'react');
    return react;
  });

  let language = 'en';
  let revision = 0;
  let dictionaries;
  let localeListener;
  let section;
  const cleanups = [];
  const locale = {
    register(_namespace, value) {
      dictionaries = value;
      return () => { dictionaries = undefined; };
    },
    bind(namespace) {
      assert.equal(namespace, 'orbat-agent-settings');
      return (key, values = {}) => {
        const template = dictionaries?.[language]?.[key] || key;
        return template.replace(/\{(\w+)\}/g, (_match, name) => String(values[name] ?? ''));
      };
    },
    getSnapshot() { return { locale: language, revision }; },
    subscribe(listener) {
      localeListener = listener;
      return () => { if (localeListener === listener) localeListener = undefined; };
    },
  };
  const ctx = {
    locale,
    effect(callback) {
      const cleanup = callback();
      if (typeof cleanup === 'function') cleanups.push(cleanup);
    },
    on(event, listener) {
      assert.equal(event, 'locale/change');
      localeListener = listener;
      return () => { if (localeListener === listener) localeListener = undefined; };
    },
    slots: {
      inject(name, callback) {
        assert.equal(name, 'settings.section');
        const cleanup = callback();
        return cleanup;
      },
      register(definition, render) {
        section = { definition, render };
        return () => { section = undefined; };
      },
    },
  };

  client.apply(ctx);
  assert.equal(section.definition.id, 'orbat-agent');
  assert.equal(section.definition.label(), 'ORBAT');
  const element = section.render();
  const tree = element.type(element.props);
  const englishText = collectText(tree).join('\n');
  assert.match(englishText, /PNG background/);
  assert.match(englishText, /Default output directory/);
  assert.match(englishText, /Workflow self-check/);
  assert.match(englishText, /SVG exports always keep transparency/);

  language = 'zh';
  revision++;
  localeListener?.();
  assert.equal(section.definition.label(), '编制图');
  const chineseElement = section.render();
  const chineseTree = chineseElement.type(chineseElement.props);
  const chineseText = collectText(chineseTree).join('\n');
  assert.match(chineseText, /PNG 背景/);
  assert.match(chineseText, /默认输出目录/);
  assert.match(chineseText, /插件工作流自检/);

  cleanups.reverse().forEach((cleanup) => cleanup());
  assert.equal(section, undefined);
});
