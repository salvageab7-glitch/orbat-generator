import { createHash, timingSafeEqual } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { lstat, mkdir, mkdtemp, open, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { PassThrough, Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createInflateRaw } from 'node:zlib';

// Pinned from the official Node.js v24.22.3 SHASUMS256.txt:
// https://nodejs.org/dist/v24.22.3/SHASUMS256.txt
export const NODE_VERSION = '24.22.3';
export const NODE_ARCHIVE_NAME = `node-v${NODE_VERSION}-win-x64.zip`;
export const NODE_ARCHIVE_URL = `https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE_NAME}`;
export const NODE_ARCHIVE_SHA256 = 'e612af99f626ab415ea225af6bce5c971feb448cb5cae250bb1c3fa50c5f7d9f';
// Also pinned from the same SHASUMS256.txt (win-x64/node.exe), so cached files are rechecked.
export const NODE_EXE_SHA256 = '86fc4785327db5f5c7558dc6156c543b433c313e813a222e088086222ab4afa6';
export const MAX_NODE_ARCHIVE_BYTES = 64 * 1024 * 1024;
const MAX_NODE_EXE_BYTES = 256 * 1024 * 1024;
const MAX_LICENSE_BYTES = 2 * 1024 * 1024;
const MAX_CENTRAL_DIRECTORY_BYTES = 8 * 1024 * 1024;
const MAX_ZIP_ENTRIES = 8_192;
const DOWNLOAD_TIMEOUT_MS = 120_000;

const inflightInstallations = new Map();
const CRC32_TABLE = new Uint32Array(256);
for (let i = 0; i < CRC32_TABLE.length; i++) {
  let value = i;
  for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  CRC32_TABLE[i] = value >>> 0;
}

export class NodeRuntimeError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'NodeRuntimeError';
    this.code = code;
  }
}

export function parseNodeVersion(value) {
  if (typeof value !== 'string') return null;
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(value.trim());
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    version: `${match[1]}.${match[2]}.${match[3]}`,
  };
}

function isAbort(error) {
  return error?.name === 'AbortError' || error?.code === 'ABORT_ERR';
}

function abortSignal(signal, timeoutMs) {
  const timeout = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

function fail(code, message, cause) {
  throw new NodeRuntimeError(code, message, cause ? { cause } : undefined);
}

function crc32Update(crc, bytes) {
  let value = crc;
  for (const byte of bytes) value = (value >>> 8) ^ CRC32_TABLE[(value ^ byte) & 0xff];
  return value >>> 0;
}

async function verifyNodeExeHash(executable) {
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(executable)) digest.update(chunk);
  const actual = Buffer.from(digest.digest('hex'), 'ascii');
  const expected = Buffer.from(NODE_EXE_SHA256, 'ascii');
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

async function readExactly(handle, length, position, label) {
  if (!Number.isSafeInteger(length) || length < 0) fail('NODE_ARCHIVE_INVALID', `Invalid ZIP ${label} length.`);
  const buffer = Buffer.alloc(length);
  let received = 0;
  while (received < length) {
    const { bytesRead } = await handle.read(buffer, received, length - received, position + received);
    if (bytesRead === 0) fail('NODE_ARCHIVE_INVALID', `Unexpected end of ZIP while reading ${label}.`);
    received += bytesRead;
  }
  return buffer;
}

async function findZipEntries(zipPath, desiredNames) {
  const zip = await open(zipPath, 'r');
  try {
    const info = await zip.stat();
    if (!info.isFile() || info.size < 22 || info.size > MAX_NODE_ARCHIVE_BYTES) {
      fail('NODE_ARCHIVE_INVALID', 'Node.js archive has an invalid size.');
    }
    const tailLength = Math.min(info.size, 22 + 65_535);
    const tailStart = info.size - tailLength;
    const tail = await readExactly(zip, tailLength, tailStart, 'end record');
    let endOffset = -1;
    for (let offset = tail.length - 22; offset >= 0; offset--) {
      if (tail.readUInt32LE(offset) !== 0x06054b50) continue;
      const commentLength = tail.readUInt16LE(offset + 20);
      if (offset + 22 + commentLength === tail.length) {
        endOffset = offset;
        break;
      }
    }
    if (endOffset < 0) fail('NODE_ARCHIVE_INVALID', 'Node.js ZIP end record is missing or malformed.');

    const end = tail.subarray(endOffset);
    const diskNumber = end.readUInt16LE(4);
    const centralDisk = end.readUInt16LE(6);
    const entriesOnDisk = end.readUInt16LE(8);
    const entryCount = end.readUInt16LE(10);
    const centralSize = end.readUInt32LE(12);
    const centralOffset = end.readUInt32LE(16);
    const endRecordPosition = tailStart + endOffset;
    if (
      diskNumber !== 0 || centralDisk !== 0 || entriesOnDisk !== entryCount ||
      entryCount === 0xffff || centralSize === 0xffffffff || centralOffset === 0xffffffff ||
      entryCount > MAX_ZIP_ENTRIES || centralSize > MAX_CENTRAL_DIRECTORY_BYTES ||
      centralOffset + centralSize > endRecordPosition
    ) {
      fail('NODE_ARCHIVE_INVALID', 'Node.js ZIP uses unsupported multi-disk, ZIP64, or oversized directory metadata.');
    }

    const central = await readExactly(zip, centralSize, centralOffset, 'central directory');
    const wanted = new Set(desiredNames);
    const found = new Map();
    let offset = 0;
    for (let index = 0; index < entryCount; index++) {
      if (offset + 46 > central.length || central.readUInt32LE(offset) !== 0x02014b50) {
        fail('NODE_ARCHIVE_INVALID', 'Node.js ZIP central directory entry is malformed.');
      }
      const versionMadeBy = central.readUInt16LE(offset + 4);
      const flags = central.readUInt16LE(offset + 8);
      const method = central.readUInt16LE(offset + 10);
      const crc = central.readUInt32LE(offset + 16);
      const compressedSize = central.readUInt32LE(offset + 20);
      const uncompressedSize = central.readUInt32LE(offset + 24);
      const nameLength = central.readUInt16LE(offset + 28);
      const extraLength = central.readUInt16LE(offset + 30);
      const commentLength = central.readUInt16LE(offset + 32);
      const diskStart = central.readUInt16LE(offset + 34);
      const externalAttributes = central.readUInt32LE(offset + 38);
      const localHeaderOffset = central.readUInt32LE(offset + 42);
      const recordEnd = offset + 46 + nameLength + extraLength + commentLength;
      if (recordEnd > central.length || diskStart !== 0) {
        fail('NODE_ARCHIVE_INVALID', 'Node.js ZIP entry has invalid bounds or a non-zero disk number.');
      }
      const name = central.subarray(offset + 46, offset + 46 + nameLength).toString('utf8');
      offset = recordEnd;
      if (!wanted.has(name)) continue;
      if (found.has(name)) fail('NODE_ARCHIVE_INVALID', `Node.js ZIP contains duplicate ${name} entries.`);
      if (
        (flags & 0x0001) !== 0 || (flags & ~0x080e) !== 0 ||
        (method !== 0 && method !== 8) ||
        compressedSize === 0xffffffff || uncompressedSize === 0xffffffff ||
        localHeaderOffset === 0xffffffff || compressedSize > MAX_NODE_ARCHIVE_BYTES ||
        uncompressedSize > (name.endsWith('/node.exe') ? MAX_NODE_EXE_BYTES : MAX_LICENSE_BYTES) ||
        (externalAttributes & 0x10) !== 0
      ) {
        fail('NODE_ARCHIVE_INVALID', `Node.js ZIP entry ${name} uses unsupported flags, compression, or size.`);
      }
      const creatorSystem = versionMadeBy >>> 8;
      const unixMode = externalAttributes >>> 16;
      const unixType = unixMode & 0o170000;
      if (creatorSystem === 3 && unixType !== 0 && unixType !== 0o100000) {
        fail('NODE_ARCHIVE_INVALID', `Node.js ZIP entry ${name} is not a regular file.`);
      }
      found.set(name, {
        name,
        flags,
        method,
        crc,
        compressedSize,
        uncompressedSize,
        localHeaderOffset,
        centralDirectoryOffset: centralOffset,
      });
    }
    if (offset !== central.length) fail('NODE_ARCHIVE_INVALID', 'Node.js ZIP central directory has unparsed data.');
    for (const name of wanted) {
      if (!found.has(name)) fail('NODE_ARCHIVE_INVALID', `Node.js ZIP is missing ${name}.`);
    }
    return found;
  } catch (error) {
    if (error instanceof NodeRuntimeError) throw error;
    throw new NodeRuntimeError('NODE_ARCHIVE_INVALID', 'Could not inspect the Node.js ZIP archive.', { cause: error });
  } finally {
    await zip.close();
  }
}

async function extractZipEntry(zipPath, entry, destination, signal) {
  const zip = await open(zipPath, 'r');
  try {
    const local = await readExactly(zip, 30, entry.localHeaderOffset, 'local file header');
    if (local.readUInt32LE(0) !== 0x04034b50) fail('NODE_ARCHIVE_INVALID', `ZIP local header for ${entry.name} is invalid.`);
    const localFlags = local.readUInt16LE(6);
    const localMethod = local.readUInt16LE(8);
    const localNameLength = local.readUInt16LE(26);
    const localExtraLength = local.readUInt16LE(28);
    if (localFlags !== entry.flags || localMethod !== entry.method) {
      fail('NODE_ARCHIVE_INVALID', `ZIP local header for ${entry.name} disagrees with its central directory.`);
    }
    const localName = await readExactly(zip, localNameLength, entry.localHeaderOffset + 30, 'local file name');
    if (localName.toString('utf8') !== entry.name) fail('NODE_ARCHIVE_INVALID', `ZIP local path for ${entry.name} does not match.`);
    const dataStart = entry.localHeaderOffset + 30 + localNameLength + localExtraLength;
    const dataEnd = dataStart + entry.compressedSize;
    if (!Number.isSafeInteger(dataEnd) || dataEnd > entry.centralDirectoryOffset || entry.compressedSize === 0) {
      fail('NODE_ARCHIVE_INVALID', `ZIP compressed data for ${entry.name} has invalid bounds.`);
    }

    const maxOutput = entry.name.endsWith('/node.exe') ? MAX_NODE_EXE_BYTES : MAX_LICENSE_BYTES;
    let uncompressed = 0;
    let crc = 0xffffffff;
    const check = new Transform({
      transform(chunk, _encoding, callback) {
        uncompressed += chunk.length;
        if (uncompressed > maxOutput || uncompressed > entry.uncompressedSize) {
          callback(new NodeRuntimeError('NODE_ARCHIVE_INVALID', `ZIP entry ${entry.name} exceeded its declared size.`));
          return;
        }
        crc = crc32Update(crc, chunk);
        callback(null, chunk);
      },
      flush(callback) {
        if (uncompressed !== entry.uncompressedSize || ((crc ^ 0xffffffff) >>> 0) !== entry.crc) {
          callback(new NodeRuntimeError('NODE_ARCHIVE_INVALID', `ZIP size or CRC check failed for ${entry.name}.`));
          return;
        }
        callback();
      },
    });
    const input = createReadStream(zipPath, { start: dataStart, end: dataEnd - 1, highWaterMark: 64 * 1024 });
    const decoder = entry.method === 8 ? createInflateRaw() : new PassThrough();
    await pipeline(input, decoder, check, createWriteStream(destination, { flags: 'wx', mode: 0o600 }), { signal });
  } catch (error) {
    await rm(destination, { force: true }).catch(() => {});
    if (error instanceof NodeRuntimeError) throw error;
    throw new NodeRuntimeError('NODE_ARCHIVE_INVALID', `Could not safely extract ${entry.name} from Node.js ZIP.`, { cause: error });
  } finally {
    await zip.close();
  }
}

async function verifyArchiveSha256(zipPath, expectedSha256 = NODE_ARCHIVE_SHA256) {
  if (!/^[a-f0-9]{64}$/i.test(expectedSha256)) fail('NODE_CHECKSUM_INVALID', 'The pinned Node.js SHA-256 value is invalid.');
  const info = await stat(zipPath);
  if (!info.isFile() || info.size < 1 || info.size > MAX_NODE_ARCHIVE_BYTES) {
    fail('NODE_ARCHIVE_INVALID', 'Node.js archive has an invalid size.');
  }
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(zipPath)) digest.update(chunk);
  const actual = Buffer.from(digest.digest('hex'), 'ascii');
  const expected = Buffer.from(expectedSha256.toLowerCase(), 'ascii');
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    fail('NODE_CHECKSUM_MISMATCH', 'Downloaded Node.js ZIP failed the pinned official SHA-256 check; the file was discarded.');
  }
  return actual.toString('ascii');
}

async function downloadArchive(fetchImpl, zipPath, signal) {
  const deadline = abortSignal(signal, DOWNLOAD_TIMEOUT_MS);
  let response;
  try {
    response = await fetchImpl(NODE_ARCHIVE_URL, { method: 'GET', redirect: 'error', signal: deadline });
  } catch (cause) {
    if (isAbort(cause) && signal?.aborted) signal.throwIfAborted();
    throw new NodeRuntimeError('NODE_DOWNLOAD_FAILED', `Could not connect to the official Node.js download: ${cause?.message ?? cause}`, { cause });
  }
  let responseOrigin;
  try {
    responseOrigin = response?.url ? new URL(response.url).origin : 'https://nodejs.org';
  } catch {
    responseOrigin = '';
  }
  if (!response?.ok || !response.body || responseOrigin !== 'https://nodejs.org') {
    await response?.body?.cancel().catch(() => {});
    fail('NODE_DOWNLOAD_FAILED', `Official Node.js download returned an unexpected HTTP response (${response?.status ?? 'no response'}).`);
  }
  const declaredLength = Number(response.headers?.get?.('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_NODE_ARCHIVE_BYTES) {
    await response.body.cancel().catch(() => {});
    fail('NODE_ARCHIVE_TOO_LARGE', 'Official Node.js ZIP exceeds the 64 MiB download limit.');
  }

  const digest = createHash('sha256');
  let received = 0;
  const meter = new Transform({
    transform(chunk, _encoding, callback) {
      received += chunk.length;
      if (received > MAX_NODE_ARCHIVE_BYTES) {
        callback(new NodeRuntimeError('NODE_ARCHIVE_TOO_LARGE', 'Official Node.js ZIP exceeds the 64 MiB download limit.'));
        return;
      }
      digest.update(chunk);
      callback(null, chunk);
    },
  });
  try {
    await pipeline(
      Readable.fromWeb(response.body),
      meter,
      createWriteStream(zipPath, { flags: 'wx', mode: 0o600 }),
      { signal: deadline },
    );
  } catch (cause) {
    await rm(zipPath, { force: true }).catch(() => {});
    if (isAbort(cause) && signal?.aborted) signal.throwIfAborted();
    if (cause instanceof NodeRuntimeError) throw cause;
    throw new NodeRuntimeError('NODE_DOWNLOAD_FAILED', `Node.js download did not complete: ${cause?.message ?? cause}`, { cause });
  }
  const actual = Buffer.from(digest.digest('hex'), 'ascii');
  const expected = Buffer.from(NODE_ARCHIVE_SHA256, 'ascii');
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    await rm(zipPath, { force: true }).catch(() => {});
    fail('NODE_CHECKSUM_MISMATCH', 'Downloaded Node.js ZIP failed the pinned official SHA-256 check; the file was discarded.');
  }
  if (declaredLength > 0 && received !== declaredLength) {
    await rm(zipPath, { force: true }).catch(() => {});
    fail('NODE_DOWNLOAD_FAILED', 'Downloaded Node.js ZIP length did not match the server response.');
  }
  return { received, sha256: actual.toString('ascii') };
}

function isWithin(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

async function ensureRealDirectory(directory, realBase) {
  await mkdir(directory, { recursive: true });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    fail('NODE_CACHE_UNSAFE', 'The private Node.js cache path is not a normal directory.');
  }
  const realDirectory = await realpath(directory);
  if (!isWithin(realBase, realDirectory)) {
    fail('NODE_CACHE_UNSAFE', 'The private Node.js cache resolves outside LOCALAPPDATA.');
  }
}

async function provisionNode({ localAppData, fetchImpl, signal, validateExecutable }) {
  if (process.platform !== 'win32' || process.arch !== 'x64') {
    fail('NODE_PLATFORM_UNSUPPORTED', 'Automatic Node.js provisioning currently supports Windows x64 only.');
  }
  if (typeof fetchImpl !== 'function') fail('NODE_DOWNLOAD_UNAVAILABLE', 'This Agent runtime cannot download Node.js over HTTPS.');
  if (typeof validateExecutable !== 'function') {
    fail('NODE_VERSION_CHECK_UNAVAILABLE', 'The Host subprocess service cannot verify the downloaded Node.js runtime.');
  }
  if (typeof localAppData !== 'string' || !path.isAbsolute(localAppData) || localAppData.startsWith('\\\\')) {
    fail('NODE_CACHE_UNSAFE', 'A local, absolute LOCALAPPDATA directory is required for Node.js provisioning.');
  }

  const localRoot = await realpath(localAppData).catch((cause) => {
    throw new NodeRuntimeError('NODE_CACHE_UNSAFE', 'LOCALAPPDATA does not exist or cannot be resolved.', { cause });
  });
  const runtimeRoot = path.join(path.resolve(localAppData), 'OrbatGeneratorDshPlugin', 'Node');
  const finalRoot = path.join(runtimeRoot, `v${NODE_VERSION}-win-x64`);
  const finalExe = path.join(finalRoot, 'node.exe');
  const finalLicense = path.join(finalRoot, 'LICENSE');
  const validInstalled = async () => {
    const [exeInfo, licenseInfo] = await Promise.all([
      stat(finalExe).catch(() => null),
      stat(finalLicense).catch(() => null),
    ]);
    if (!exeInfo?.isFile() || exeInfo.size < 1_000_000 || !licenseInfo?.isFile() || licenseInfo.size === 0) return false;
    if (!(await verifyNodeExeHash(finalExe))) return false;
    try {
      const rootInfo = await lstat(finalRoot);
      if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink() || !isWithin(localRoot, await realpath(finalRoot))) return false;
      return (await validateExecutable(finalExe, { signal })) === NODE_VERSION;
    } catch (error) {
      if (isAbort(error)) throw error;
      return false;
    }
  };
  if (await validInstalled()) return finalExe;
  signal?.throwIfAborted();

  await ensureRealDirectory(runtimeRoot, localRoot);
  const stageRoot = await mkdtemp(path.join(runtimeRoot, '.node-24-provision-'));
  const stageInstall = path.join(stageRoot, 'install');
  const zipPath = path.join(stageRoot, 'node.zip');
  const stageExe = path.join(stageInstall, 'node.exe');
  const stageLicense = path.join(stageInstall, 'LICENSE');
  try {
    await mkdir(stageInstall, { recursive: false });
    await downloadArchive(fetchImpl, zipPath, signal);
    const prefix = `node-v${NODE_VERSION}-win-x64/`;
    const entries = await findZipEntries(zipPath, [`${prefix}node.exe`, `${prefix}LICENSE`]);
    await extractZipEntry(zipPath, entries.get(`${prefix}node.exe`), stageExe, signal);
    await extractZipEntry(zipPath, entries.get(`${prefix}LICENSE`), stageLicense, signal);
    await rm(zipPath, { force: true });
    signal?.throwIfAborted();
    if (!(await verifyNodeExeHash(stageExe))) {
      fail('NODE_CHECKSUM_MISMATCH', 'Extracted node.exe failed the pinned official SHA-256 check.');
    }
    if ((await validateExecutable(stageExe, { signal })) !== NODE_VERSION) {
      fail('NODE_VERSION_MISMATCH', `The downloaded binary did not report the pinned Node.js v${NODE_VERSION}.`);
    }
    await writeFile(path.join(stageInstall, 'runtime.json'), JSON.stringify({
      version: NODE_VERSION,
      architecture: 'win-x64',
      archive: NODE_ARCHIVE_URL,
      sha256: NODE_ARCHIVE_SHA256,
    }, null, 2), { flag: 'wx', mode: 0o600 });

    const existing = await lstat(finalRoot).catch(() => null);
    if (existing?.isSymbolicLink() || (existing && !existing.isDirectory())) {
      fail('NODE_CACHE_UNSAFE', 'The managed Node.js cache target is not a normal directory.');
    }
    if (existing) await rm(finalRoot, { recursive: true, force: true });
    await rename(stageInstall, finalRoot);
    if (!(await validInstalled())) {
      await rm(finalRoot, { recursive: true, force: true });
      fail('NODE_INSTALL_VERIFY_FAILED', 'Installed Node.js did not pass the version and license checks.');
    }
    return finalExe;
  } catch (error) {
    if (error instanceof NodeRuntimeError || isAbort(error)) throw error;
    throw new NodeRuntimeError('NODE_PROVISION_FAILED', `Could not install the verified Node.js runtime: ${error?.message ?? error}`, { cause: error });
  } finally {
    await rm(stageRoot, { recursive: true, force: true }).catch(() => {});
  }
}

/**
 * Installs the pinned official Node.js v24 runtime in the user's LocalAppData.
 * The caller validates the extracted executable through its managed subprocess
 * provider before it is used for rendering.
 */
function waitWithSignal(promise, signal) {
  if (!signal) return promise;
  if (signal.aborted) {
    try {
      signal.throwIfAborted();
    } catch (error) {
      return Promise.reject(error);
    }
    return Promise.reject(new DOMException('The operation was aborted.', 'AbortError'));
  }
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      cleanup();
      try {
        signal.throwIfAborted();
      } catch (error) {
        reject(error);
        return;
      }
      reject(new DOMException('The operation was aborted.', 'AbortError'));
    };
    const cleanup = () => signal.removeEventListener('abort', onAbort);
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      (error) => {
        cleanup();
        reject(error);
      },
    );
  });
}

export function ensureNodeRuntime(options) {
  if (!options || typeof options.localAppData !== 'string') {
    return Promise.reject(new NodeRuntimeError('NODE_CACHE_UNSAFE', 'LOCALAPPDATA is required to install the private Node.js runtime.'));
  }
  const key = path.resolve(options.localAppData, 'OrbatGeneratorDshPlugin', 'Node', `v${NODE_VERSION}-win-x64`);
  let shared = inflightInstallations.get(key);
  if (!shared) {
    const controller = new AbortController();
    shared = { controller, waiters: 0, settled: false, promise: null };
    shared.promise = provisionNode({ ...options, signal: controller.signal }).finally(() => {
      shared.settled = true;
      if (inflightInstallations.get(key) === shared) inflightInstallations.delete(key);
    });
    // Keep a cancelled final waiter from leaving an unhandled rejection behind.
    shared.promise.catch(() => {});
    inflightInstallations.set(key, shared);
  }

  shared.waiters++;
  return waitWithSignal(shared.promise, options.signal).finally(() => {
    shared.waiters--;
    if (!shared.settled && shared.waiters === 0) shared.controller.abort();
  });
}

/** Extract only the two fixed archive files; no ZIP entry path is ever written. */
export async function extractOfficialNodeZip(zipPath, destinationDirectory, { signal } = {}) {
  const prefix = `node-v${NODE_VERSION}-win-x64/`;
  const entries = await findZipEntries(zipPath, [`${prefix}node.exe`, `${prefix}LICENSE`]);
  await mkdir(destinationDirectory, { recursive: false });
  const exePath = path.join(destinationDirectory, 'node.exe');
  const licensePath = path.join(destinationDirectory, 'LICENSE');
  await extractZipEntry(zipPath, entries.get(`${prefix}node.exe`), exePath, signal);
  await extractZipEntry(zipPath, entries.get(`${prefix}LICENSE`), licensePath, signal);
  return { exePath, licensePath };
}

export async function verifyOfficialNodeArchive(zipPath) {
  const info = await stat(zipPath);
  if (!info.isFile() || info.size < 1 || info.size > MAX_NODE_ARCHIVE_BYTES) {
    fail('NODE_ARCHIVE_INVALID', 'Node.js archive has an invalid size.');
  }
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(zipPath)) digest.update(chunk);
  const actual = Buffer.from(digest.digest('hex'), 'ascii');
  const expected = Buffer.from(NODE_ARCHIVE_SHA256, 'ascii');
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    fail('NODE_CHECKSUM_MISMATCH', 'Node.js ZIP does not match the pinned official SHA-256.');
  }
  return actual.toString('ascii');
}

export function nodeRuntimeInstallPath(localAppData) {
  return path.join(path.resolve(localAppData), 'OrbatGeneratorDshPlugin', 'Node', `v${NODE_VERSION}-win-x64`, 'node.exe');
}

export function nodeRuntimeLicensePath(localAppData) {
  return path.join(path.dirname(nodeRuntimeInstallPath(localAppData)), 'LICENSE');
}

export function sha256BufferForTesting(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function crc32BufferForTesting(bytes) {
  return (crc32Update(0xffffffff, bytes) ^ 0xffffffff) >>> 0;
}

export const nodeRuntimeTestInternals = Object.freeze({
  findZipEntries,
  extractZipEntry,
  verifyArchiveSha256,
  downloadArchive,
});

