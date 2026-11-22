import assert from 'node:assert/strict';
import { spawn as spawnChild } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateSync } from 'node:zlib';
import { createOrbatCli } from '../lib/orbat_cli.js';

const packageRoot = fileURLToPath(new URL('..', import.meta.url));
const fixturePath = path.join(packageRoot, 'test', 'render-fixture.json');
const fixture = await readFile(fixturePath, 'utf8');

function makeCollector(maxBytes) {
  const chunks = [];
  let total = 0;
  let lossy = false;
  return {
    push(chunk) {
      const buffer = Buffer.from(chunk);
      const available = Math.max(0, maxBytes - total);
      if (available > 0) {
        const accepted = buffer.subarray(0, available);
        chunks.push(accepted);
        total += accepted.length;
      }
      if (buffer.length > available) lossy = true;
    },
    readFrom(offset = 0) {
      const all = Buffer.concat(chunks);
      return {
        text: all.subarray(offset).toString('utf8'),
        nextOffset: all.length,
        lossy,
      };
    },
  };
}

function createSubprocessProvider() {
  return {
    spawn(request) {
      assert.ok(Array.isArray(request.argv));
      assert.ok(path.isAbsolute(request.argv[0]));
      const child = spawnChild(request.argv[0], request.argv.slice(1), {
        cwd: request.cwd,
        env: request.env,
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
      });
      const stdout = makeCollector(request.stdio.stdout.maxBytes);
      const stderr = makeCollector(request.stdio.stderr.maxBytes);
      child.stdout.on('data', (chunk) => stdout.push(chunk));
      child.stderr.on('data', (chunk) => stderr.push(chunk));
      const done = new Promise((resolve) => {
        child.once('close', (exitCode, signal) => resolve({ exitCode: exitCode ?? -1, signal }));
      });
      return {
        stdin: child.stdin,
        done,
        collected: { stdout, stderr },
        terminate() {
          child.kill();
        },
        async waitForExit(signal) {
          if (signal?.aborted) return false;
          const exited = done.then(() => true);
          if (!signal) return exited;
          let onAbort;
          const aborted = new Promise((resolve) => {
            onAbort = () => resolve(false);
            signal.addEventListener('abort', onAbort, { once: true });
          });
          try {
            return await Promise.race([exited, aborted]);
          } finally {
            signal.removeEventListener('abort', onAbort);
          }
        },
      };
    },
  };
}

async function topLeftPngAlpha(pngPath) {
  const png = await readFile(pngPath);
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  let colorType = -1;
  const imageData = [];
  for (let offset = 8; offset < png.length;) {
    const length = png.readUInt32BE(offset);
    const type = png.toString('ascii', offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    if (type === 'IHDR') colorType = png[dataStart + 9];
    if (type === 'IDAT') imageData.push(png.subarray(dataStart, dataEnd));
    offset = dataEnd + 4;
    if (type === 'IEND') break;
  }
  assert.equal(colorType, 6, 'expected RGBA PNG');
  const firstRow = inflateSync(Buffer.concat(imageData));
  assert.ok(firstRow.length >= 5);
  // At pixel (0,0), PNG filters have no left/up neighbors, so its first
  // RGBA tuple is unchanged by the filter byte.
  return firstRow[4];
}

if (process.platform !== 'win32') {
  console.error('SKIP: Windows bundle integration test only.');
  process.exitCode = 0;
} else {
  const scratch = await mkdtemp(path.join(os.tmpdir(), 'orbat-adapter-e2e-'));
  const localAppData = path.join(scratch, 'local');
  await mkdir(localAppData, { recursive: true });
  const env = {
    ...process.env,
    LOCALAPPDATA: localAppData,
  };
  let outputDirectory;
  try {
    const configuredOutput = path.join(scratch, 'configured-output');
    const preferences = { whiteBackground: false, outputDirectory: configuredOutput };
    const bridge = createOrbatCli({
      subprocess: createSubprocessProvider(),
      packageRoot,
      env,
      settingsProvider: async () => ({ ...preferences }),
    });
    const transparentResult = await bridge.render(fixture, { name: 'adapter-transparent-smoke' });
    assert.equal(transparentResult.baseOutputDirectory, configuredOutput);
    outputDirectory = transparentResult.outputDirectory;
    assert.equal(transparentResult.success, true, JSON.stringify(transparentResult));
    assert.equal(transparentResult.rendered, true);
    for (const filePath of [transparentResult.pngPath, transparentResult.svgPath]) {
      assert.equal(path.isAbsolute(filePath), true);
      const info = await stat(filePath);
      assert.ok(info.isFile() && info.size > 0);
    }
    const transparentAlpha = await topLeftPngAlpha(transparentResult.pngPath);
    assert.equal(transparentAlpha, 0, 'transparent mode should leave the canvas corner transparent');

    const selfCheck = await bridge.selfCheck();
    assert.equal(selfCheck.success, true, JSON.stringify(selfCheck));
    assert.equal(selfCheck.rendered, true);
    assert.equal(selfCheck.outputDirectory, configuredOutput);

    preferences.whiteBackground = true;
    const whiteResult = await bridge.render(fixture, { name: 'adapter-white-smoke' });
    assert.equal(whiteResult.baseOutputDirectory, configuredOutput);
    assert.equal(await topLeftPngAlpha(whiteResult.pngPath), 255, 'white mode should produce an opaque canvas corner');
    console.log(JSON.stringify({
      success: transparentResult.success && whiteResult.success && selfCheck.success,
      rendered: transparentResult.rendered && whiteResult.rendered,
      nodeCount: transparentResult.nodeCount,
      transparentPngBytes: (await stat(transparentResult.pngPath)).size,
      whitePngBytes: (await stat(whiteResult.pngPath)).size,
      svgBytes: (await stat(transparentResult.svgPath)).size,
      outputBaseDirectory: transparentResult.baseOutputDirectory,
      transparentTopLeftAlpha: transparentAlpha,
      whiteTopLeftAlpha: await topLeftPngAlpha(whiteResult.pngPath),
      selfCheckSuccess: selfCheck.success,
      selfCheckChecks: selfCheck.checks,
    }));
  } finally {
    if (outputDirectory) await rm(outputDirectory, { recursive: true, force: true });
    await rm(scratch, { recursive: true, force: true });
  }
}
