import assert from 'node:assert/strict';
import { deflateRawSync } from 'node:zlib';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  crc32BufferForTesting,
  ensureNodeRuntime,
  extractOfficialNodeZip,
  NODE_ARCHIVE_SHA256,
  NODE_VERSION,
  parseNodeVersion,
  verifyOfficialNodeArchive,
} from '../lib/node_runtime.js';

function buildZip(entries) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;

  for (const { name: nameText, data } of entries) {
    const name = Buffer.from(nameText, 'utf8');
    const content = Buffer.from(data);
    const compressed = deflateRawSync(content);
    const crc = crc32BufferForTesting(content);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, name, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4); // DOS creator, version 2.0
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt32LE(0x20, 38); // DOS archive attribute, not a directory.
    central.writeUInt32LE(localOffset, 42);
    centralParts.push(central, name);
    localOffset += local.length + name.length + compressed.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localOffset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...localParts, centralDirectory, end]);
}

async function withTempDirectory(callback) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'orbat-node-runtime-test-'));
  try {
    return await callback(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test('pins a current official Node.js 24 release and parses semantic versions', () => {
  assert.equal(NODE_VERSION, '24.22.3');
  assert.match(NODE_ARCHIVE_SHA256, /^[a-f0-9]{64}$/);
  assert.deepEqual(parseNodeVersion('v24.19.0'), {
    major: 24,
    minor: 19,
    patch: 0,
    version: '24.19.0',
  });
  assert.equal(parseNodeVersion('node-24'), null);
  assert.equal(parseNodeVersion('v23.9.0')?.major >= 24, false);
});

test('extracts only the pinned Node executable and LICENSE paths', async () => {
  await withTempDirectory(async (directory) => {
    const zipPath = path.join(directory, 'node.zip');
    const output = path.join(directory, 'runtime');
    const nodeBytes = Buffer.from('fake-node-executable-content');
    const licenseBytes = Buffer.from('Node.js license fixture');
    await writeFile(zipPath, buildZip([
      { name: `node-v${NODE_VERSION}-win-x64/node.exe`, data: nodeBytes },
      { name: `node-v${NODE_VERSION}-win-x64/LICENSE`, data: licenseBytes },
      { name: '../../outside.txt', data: 'must not be extracted' },
    ]));

    const result = await extractOfficialNodeZip(zipPath, output);
    assert.deepEqual(await readFile(result.exePath), nodeBytes);
    assert.deepEqual(await readFile(result.licensePath), licenseBytes);
    await assert.rejects(readFile(path.join(directory, 'outside.txt')), { code: 'ENOENT' });
  });
});

test('rejects duplicate required ZIP entries', async () => {
  await withTempDirectory(async (directory) => {
    const zipPath = path.join(directory, 'duplicate.zip');
    const prefix = `node-v${NODE_VERSION}-win-x64/`;
    await writeFile(zipPath, buildZip([
      { name: `${prefix}node.exe`, data: 'one' },
      { name: `${prefix}node.exe`, data: 'two' },
      { name: `${prefix}LICENSE`, data: 'license' },
    ]));

    await assert.rejects(
      extractOfficialNodeZip(zipPath, path.join(directory, 'runtime')),
      (error) => error.code === 'NODE_ARCHIVE_INVALID' && /duplicate/.test(error.message),
    );
  });
});

test('rejects an archive whose SHA-256 is not the pinned official value', async () => {
  await withTempDirectory(async (directory) => {
    const zipPath = path.join(directory, 'not-official.zip');
    await writeFile(zipPath, buildZip([{ name: 'untrusted.zip-entry', data: 'not node' }]));
    await assert.rejects(
      verifyOfficialNodeArchive(zipPath),
      (error) => error.code === 'NODE_CHECKSUM_MISMATCH',
    );
  });
});

test('rejects malformed ZIP data instead of extracting partial files', async () => {
  await withTempDirectory(async (directory) => {
    const zipPath = path.join(directory, 'malformed.zip');
    await writeFile(zipPath, Buffer.from('not a zip archive'));
    await assert.rejects(
      extractOfficialNodeZip(zipPath, path.join(directory, 'runtime')),
      (error) => error.code === 'NODE_ARCHIVE_INVALID',
    );
  });
});

test('cancelling one waiter does not cancel another shared Node installation', { skip: process.platform !== 'win32' || process.arch !== 'x64' }, async () => {
  await withTempDirectory(async (localAppData) => {
    let fetchCalls = 0;
    let underlyingAborts = 0;
    const fetchImpl = async (_url, { signal }) => {
      fetchCalls++;
      return new Promise((_resolve, reject) => {
        signal.addEventListener('abort', () => {
          underlyingAborts++;
          reject(new DOMException('Download aborted.', 'AbortError'));
        }, { once: true });
      });
    };
    const first = new AbortController();
    const second = new AbortController();
    const options = {
      localAppData,
      fetchImpl,
      validateExecutable: async () => NODE_VERSION,
    };
    const firstResult = ensureNodeRuntime({ ...options, signal: first.signal })
      .then((value) => ({ value }), (error) => ({ error }));
    const secondResult = ensureNodeRuntime({ ...options, signal: second.signal })
      .then((value) => ({ value }), (error) => ({ error }));

    for (let attempt = 0; attempt < 100 && fetchCalls === 0; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    if (fetchCalls === 0) {
      const result = await firstResult;
      assert.fail(`provision failed before download: ${result.error?.message ?? 'no error'}`);
    }
    assert.equal(fetchCalls, 1, 'concurrent callers should share one download');

    first.abort();
    assert.equal((await firstResult).error?.name, 'AbortError');
    assert.equal(underlyingAborts, 0, 'one cancelled waiter must not abort the shared download');

    second.abort();
    assert.equal((await secondResult).error?.name, 'AbortError');
    for (let attempt = 0; attempt < 100 && underlyingAborts === 0; attempt++) {
      await new Promise((resolve) => setImmediate(resolve));
    }
    assert.equal(underlyingAborts, 1, 'the last cancelled waiter should abort the shared download');
  });
});
