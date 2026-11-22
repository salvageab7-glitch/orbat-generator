import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import test from 'node:test';
import {
  OrbatCliError,
  parseCliEnvelope,
  readInputText,
  resolveOutputBases,
  runManagedCli,
  sanitizeOutputName,
} from '../lib/orbat_cli.js';
import { apply, workspaceDirectoryOf } from '../index.js';

const require = createRequire(import.meta.url);

test('packaged renderer runtime remains CommonJS under the ESM bundle root', () => {
  const manifest = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.ok(manifest.files.includes('runtime/package.json'));
  assert.deepEqual(JSON.parse(readFileSync(new URL('../runtime/package.json', import.meta.url), 'utf8')), {
    private: true,
    type: 'commonjs',
  });
  assert.equal(typeof require('../runtime/cdp.js').launch, 'function');
});

test('sanitizeOutputName treats input as a label, never a path', () => {
  const result = sanitizeOutputName('../CON: 1st/Brigade. ');
  assert.equal(result.includes('/'), false);
  assert.equal(result.includes('\\'), false);
  assert.match(result, /^orbat-/);
  assert.ok(result.length <= 63);
});

test('workspace directory comes from the live agent session header', () => {
  assert.equal(workspaceDirectoryOf({ agent: { session: { header: { cwd: 'C:\\work' } } } }), 'C:\\work');
  assert.equal(workspaceDirectoryOf({ agent: { session: { header: { cwd: 'relative' } } } }), '');
  assert.equal(workspaceDirectoryOf({}), '');
});

test('output bases prefer the session workspace before legacy user folders', () => {
  const workspace = 'C:\\work\\session';
  const preferred = 'C:\\Users\\test\\Documents\\ORBAT Generator';
  const fallback = 'C:\\Users\\test\\AppData\\Local\\OrbatGeneratorDshPlugin\\Output';

  assert.deepEqual(resolveOutputBases({ workspaceDirectory: workspace, preferredOutput: preferred, fallbackOutput: fallback }), [
    'C:\\work\\session\\编制插件产物仓库',
    preferred,
    fallback,
  ]);
  assert.deepEqual(resolveOutputBases({
    settings: { outputDirectory: 'D:\\explicit' },
    workspaceDirectory: workspace,
    preferredOutput: preferred,
    fallbackOutput: fallback,
  }), ['D:\\explicit']);
  assert.deepEqual(resolveOutputBases({ preferredOutput: preferred, fallbackOutput: preferred }), [preferred]);
});

test('readInputText accepts inline JSON, absolute paths and workspace-relative paths', async () => {
  // The DSH file sandbox only guarantees the workspace; os.tmpdir() may be read-only.
  const dir = await mkdtemp(path.join(process.cwd(), '.tmp-input-'));
  try {
    const file = path.join(dir, 'tree.json');
    await writeFile(file, '\uFEFF{"options":{"uniqueDesignation":"Root","sidc":"130310002111000000000000000000"}}', 'utf8');
    assert.deepEqual(await readInputText({ json: '{"a":1}' }), { json: '{"a":1}', sourcePath: '' });
    const absolute = await readInputText({ path: file });
    assert.equal(absolute.json.startsWith('{"options"'), true);
    assert.equal(absolute.json.charCodeAt(0), 0x7b);
    assert.equal(absolute.sourcePath, file);
    const relative = await readInputText({ path: 'tree.json', workspaceDirectory: dir });
    assert.equal(relative.json, absolute.json);
    await assert.rejects(
      () => readInputText({ json: '{}', path: file }),
      (error) => error instanceof OrbatCliError && error.code === 'INPUT_AMBIGUOUS',
    );
    await assert.rejects(
      () => readInputText({ path: 'missing.json', workspaceDirectory: dir }),
      (error) => error instanceof OrbatCliError && error.code === 'INPUT_PATH_NOT_FOUND',
    );
    await assert.rejects(
      () => readInputText({ path: 'tree.json' }),
      (error) => error instanceof OrbatCliError && error.code === 'INPUT_PATH_INVALID',
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('parseCliEnvelope accepts only the expected command envelope', () => {
  assert.deepEqual(parseCliEnvelope('{"ok":true,"command":"validate","data":{}}', 'validate'), {
    ok: true,
    command: 'validate',
    data: {},
  });
  assert.throws(
    () => parseCliEnvelope('{"ok":true,"command":"render"}', 'validate'),
    (error) => error instanceof OrbatCliError && error.code === 'CLI_INVALID_ENVELOPE',
  );
  assert.throws(
    () => parseCliEnvelope('not-json', 'validate'),
    (error) => error instanceof OrbatCliError && error.code === 'CLI_INVALID_JSON',
  );
});

function createChildHarness() {
  let resolveDone;
  const writes = [];
  let terminateCalls = 0;
  let waitCalls = 0;
  const done = new Promise((resolve) => {
    resolveDone = resolve;
  });
  const handle = {
    stdin: {
      destroyed: false,
      writableEnded: false,
      write(text) {
        writes.push(text);
        resolveDone({ exitCode: 0, signal: null });
        return true;
      },
    },
    done,
    collected: {
      stdout: { readFrom: () => ({ text: '{"ok":true}', lossy: false }) },
      stderr: { readFrom: () => ({ text: '', lossy: false }) },
    },
    terminate() {
      terminateCalls++;
    },
    async waitForExit() {
      waitCalls++;
      return true;
    },
  };
  return {
    handle,
    writes,
    get terminateCalls() { return terminateCalls; },
    get waitCalls() { return waitCalls; },
    subprocess: { spawn: () => handle },
  };
}

test('managed render timeout sends one cooperative shutdown before termination', async () => {
  const child = createChildHarness();
  const result = await runManagedCli(child.subprocess, {
    argv: ['orbat-cli.exe', 'render', '--cancelable'],
    cwd: 'C:\\plugin',
    stdio: { stdin: 'pipe', stdout: { maxBytes: 1024 }, stderr: { maxBytes: 1024 } },
    graceMs: 1000,
  }, { cancelable: true, timeoutMs: 1 });

  assert.equal(result.timedOut, true);
  assert.deepEqual(child.writes, ['ORBAT_SHUTDOWN\n']);
  assert.equal(child.terminateCalls, 0);
  assert.ok(child.waitCalls >= 1);
});

test('managed render cancellation does not force-terminate before cooperative exit', async () => {
  const child = createChildHarness();
  const controller = new AbortController();
  const operation = runManagedCli(child.subprocess, {
    argv: ['orbat-cli.exe', 'render', '--cancelable'],
    cwd: 'C:\\plugin',
    stdio: { stdin: 'pipe', stdout: { maxBytes: 1024 }, stderr: { maxBytes: 1024 } },
    graceMs: 1000,
  }, { signal: controller.signal, cancelable: true, timeoutMs: 5000 });
  controller.abort();

  await assert.rejects(operation, { name: 'AbortError' });
  assert.deepEqual(child.writes, ['ORBAT_SHUTDOWN\n']);
  assert.equal(child.terminateCalls, 0);
  assert.ok(child.waitCalls >= 1);
});

test('Host adapter registers dependency-free raw-schema tools with visible structured issues', async () => {
  const registered = [];
  const cleanupCalls = [];
  const registeredRoutes = [];
  let effectCleanup;
  const ctx = {
    subprocess: { spawn() { throw new Error('not used in this registration test'); } },
    webServer: {
      register(route) {
        registeredRoutes.push(route);
        return () => cleanupCalls.push('preferences-route');
      },
    },
    tools: {
      register(definition) {
        registered.push(definition);
        return () => cleanupCalls.push(definition.name);
      },
    },
    effect(callback) {
      effectCleanup = callback();
    },
  };

  apply(ctx);
  assert.deepEqual(registered.map((tool) => tool.name), [
    'orbat_validate_json',
    'orbat_render_json',
    'orbat_workflow_self_check',
  ]);
  assert.deepEqual(registeredRoutes.map((route) => route.path), ['/orbat-agent']);
  assert.equal(registered[0].parameters.required, undefined);
  assert.ok(registered[0].parameters.properties.path);
  assert.deepEqual(registered[0].parameters.anyOf, [{ required: ['json'] }, { required: ['path'] }]);
  assert.deepEqual(registered[2].parameters.type, 'object');
  await assert.rejects(
    registered[2].execute({ unexpected: true }, { signal: new AbortController().signal }),
    { name: 'TypeError' },
  );
  assert.deepEqual(registered[0].output.schema.required, ['success', 'summary']);
  assert.match(registered[0].description, /在生成或修改编制 JSON 后校验/);
  await assert.rejects(
    registered[0].execute({ json: '' }, { signal: new AbortController().signal }),
    { name: 'TypeError' },
  );
  const rendered = registered[0].output.render({}, {
    success: true,
    valid: false,
    summary: '2 red issues',
    issues: [{ level: 'red', path: 'root/1st Bde', message: 'Invalid SIDC' }],
  });
  assert.match(rendered[0].text, /root\/1st Bde/);
  assert.match(rendered[0].text, /Invalid SIDC/);

  effectCleanup();
  assert.deepEqual(cleanupCalls, [
    'orbat_workflow_self_check',
    'orbat_render_json',
    'orbat_validate_json',
    'preferences-route',
  ]);
});
