import { randomBytes } from 'node:crypto';
import { isIP } from 'node:net';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const MAX_SETTINGS_BYTES = 16 * 1024;
const MAX_OUTPUT_DIRECTORY_CHARS = 1_024;
export const DEFAULT_PREFERENCES = Object.freeze({
  whiteBackground: true,
  outputDirectory: '',
});

export class PreferencesError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'PreferencesError';
    this.code = code;
  }
}

function normalizeOutputDirectory(value) {
  if (typeof value !== 'string') {
    throw new PreferencesError('INVALID_OUTPUT_DIRECTORY', 'Output directory must be a string.');
  }
  const trimmed = value.trim();
  if (!trimmed) return '';
  if (trimmed.length > MAX_OUTPUT_DIRECTORY_CHARS || /[\u0000-\u001f]/.test(trimmed)) {
    throw new PreferencesError('INVALID_OUTPUT_DIRECTORY', 'Output directory is too long or contains control characters.');
  }
  const driveAbsolute = /^[a-z]:[\\/]/i.test(trimmed);
  const uncAbsolute = /^\\\\[^\\]+\\[^\\]+/.test(trimmed);
  const devicePath = trimmed.startsWith('\\\\?\\') || trimmed.startsWith('\\\\.\\');
  if ((!driveAbsolute && !uncAbsolute) || devicePath) {
    throw new PreferencesError('INVALID_OUTPUT_DIRECTORY', 'Output directory must be a normal absolute Windows path.');
  }
  return path.win32.normalize(trimmed);
}

export function normalizePreferences(value, { partial = false } = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new PreferencesError('INVALID_SETTINGS', 'Settings must be a JSON object.');
  }
  for (const key of Object.keys(value)) {
    if (!['whiteBackground', 'outputDirectory'].includes(key)) {
      throw new PreferencesError('UNKNOWN_SETTING', `Unknown setting: ${key}.`);
    }
  }
  const normalized = {};
  if (!partial || Object.hasOwn(value, 'whiteBackground')) {
    const background = Object.hasOwn(value, 'whiteBackground') ? value.whiteBackground : DEFAULT_PREFERENCES.whiteBackground;
    if (typeof background !== 'boolean') {
      throw new PreferencesError('INVALID_BACKGROUND', 'whiteBackground must be a boolean.');
    }
    normalized.whiteBackground = background;
  }
  if (!partial || Object.hasOwn(value, 'outputDirectory')) {
    const directory = Object.hasOwn(value, 'outputDirectory') ? value.outputDirectory : DEFAULT_PREFERENCES.outputDirectory;
    normalized.outputDirectory = normalizeOutputDirectory(directory);
  }
  if (partial && Object.keys(normalized).length === 0) {
    throw new PreferencesError('EMPTY_SETTINGS_PATCH', 'Provide at least one supported setting.');
  }
  return normalized;
}

export function getDefaultOutputDirectory({ userProfile = process.env.USERPROFILE || os.homedir() } = {}) {
  return path.join(userProfile, 'Documents', 'ORBAT Generator');
}

export function createPreferencesStore({ localAppData = process.env.LOCALAPPDATA, userProfile } = {}) {
  const resolvedUserProfile = userProfile || process.env.USERPROFILE || os.homedir();
  const base = localAppData || path.join(resolvedUserProfile, 'AppData', 'Local');
  const directory = path.resolve(base, 'OrbatGeneratorDshPlugin');
  const filePath = path.join(directory, 'settings.json');
  let writeQueue = Promise.resolve();

  async function read() {
    let text;
    try {
      text = await readFile(filePath, 'utf8');
    } catch (error) {
      if (error?.code === 'ENOENT') return { ...DEFAULT_PREFERENCES };
      throw new PreferencesError('SETTINGS_READ_FAILED', `Could not read plugin settings: ${error?.message ?? error}`, { cause: error });
    }
    if (Buffer.byteLength(text, 'utf8') > MAX_SETTINGS_BYTES) {
      throw new PreferencesError('SETTINGS_FILE_TOO_LARGE', 'Plugin settings file exceeds its safe size limit.');
    }
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (error) {
      throw new PreferencesError('SETTINGS_FILE_INVALID', 'Plugin settings file contains invalid JSON.', { cause: error });
    }
    return { ...DEFAULT_PREFERENCES, ...normalizePreferences(parsed) };
  }

  function update(patch) {
    const safePatch = normalizePreferences(patch, { partial: true });
    const operation = writeQueue.then(async () => {
      const next = { ...(await read()), ...safePatch };
      const serialized = JSON.stringify(next, null, 2) + '\n';
      if (Buffer.byteLength(serialized, 'utf8') > MAX_SETTINGS_BYTES) {
        throw new PreferencesError('SETTINGS_FILE_TOO_LARGE', 'Plugin settings file exceeds its safe size limit.');
      }
      await mkdir(directory, { recursive: true });
      const temporary = `${filePath}.tmp-${process.pid}-${randomBytes(6).toString('hex')}`;
      try {
        await writeFile(temporary, serialized, { encoding: 'utf8', flag: 'wx' });
        await rename(temporary, filePath);
      } catch (error) {
        await rm(temporary, { force: true }).catch(() => {});
        throw new PreferencesError('SETTINGS_WRITE_FAILED', `Could not save plugin settings: ${error?.message ?? error}`, { cause: error });
      }
      return next;
    });
    writeQueue = operation.then(() => undefined, () => undefined);
    return operation;
  }

  const defaultOutputDirectory = () => getDefaultOutputDirectory({ userProfile: resolvedUserProfile });
  return Object.freeze({ filePath, directory, read, update, getDefaultOutputDirectory: defaultOutputDirectory });
}

export const PREFERENCES_LIMITS = Object.freeze({
  maxBodyBytes: MAX_SETTINGS_BYTES,
  maxOutputDirectoryChars: MAX_OUTPUT_DIRECTORY_CHARS,
});

function isLoopbackHostname(hostname) {
  const value = String(hostname || '').toLowerCase().replace(/^\[|\]$/g, '');
  return value === 'localhost' || value === '::1' || (isIP(value) === 4 && value.split('.')[0] === '127');
}

function isLocalRequest(req) {
  const origin = req.headers?.origin;
  if (typeof origin === 'string' && origin !== 'null') {
    try {
      const parsed = new URL(origin);
      if (!isLoopbackHostname(parsed.hostname)) return false;
    } catch {
      return false;
    }
  }
  const hostHeader = req.headers?.host;
  if (typeof hostHeader !== 'string' || !hostHeader) return origin === 'null';
  try {
    return isLoopbackHostname(new URL(`http://${hostHeader}`).hostname);
  } catch {
    return false;
  }
}

function sendJson(res, statusCode, body) {
  if (res.writableEnded || res.destroyed) return;
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}

async function readJsonBody(req) {
  const contentType = String(req.headers?.['content-type'] || '').split(';', 1)[0].trim().toLowerCase();
  if (contentType !== 'application/json') {
    throw new PreferencesError('CONTENT_TYPE_REQUIRED', 'Request must use application/json.');
  }
  const declared = Number(req.headers?.['content-length']);
  if (Number.isFinite(declared) && declared > MAX_SETTINGS_BYTES) {
    throw new PreferencesError('SETTINGS_BODY_TOO_LARGE', 'Settings request body is too large.');
  }
  const chunks = [];
  let total = 0;
  let timeout;
  try {
    const body = await new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        error ? reject(error) : resolve(value);
      };
      timeout = setTimeout(() => finish(new PreferencesError('SETTINGS_BODY_TIMEOUT', 'Settings request body timed out.')), 15_000);
      req.on('data', (chunk) => {
        total += chunk.length;
        if (total > MAX_SETTINGS_BYTES) {
          finish(new PreferencesError('SETTINGS_BODY_TOO_LARGE', 'Settings request body is too large.'));
          req.resume?.();
          return;
        }
        chunks.push(Buffer.from(chunk));
      });
      req.on('end', () => finish(null, Buffer.concat(chunks).toString('utf8')));
      req.on('error', (error) => finish(new PreferencesError('SETTINGS_BODY_READ_FAILED', 'Could not read settings request body.', { cause: error })));
      req.on('aborted', () => finish(new PreferencesError('SETTINGS_BODY_ABORTED', 'Settings request was interrupted.')));
    });
    return JSON.parse(body || '{}');
  } catch (error) {
    if (error instanceof PreferencesError) throw error;
    throw new PreferencesError('SETTINGS_BODY_INVALID', 'Request body must be valid JSON.', { cause: error });
  } finally {
    clearTimeout(timeout);
  }
}

function statusFor(error) {
  if (['CONTENT_TYPE_REQUIRED', 'SETTINGS_BODY_INVALID', 'INVALID_SETTINGS', 'UNKNOWN_SETTING', 'INVALID_BACKGROUND', 'INVALID_OUTPUT_DIRECTORY', 'EMPTY_SETTINGS_PATCH'].includes(error?.code)) return 400;
  if (['SETTINGS_BODY_TOO_LARGE'].includes(error?.code)) return 413;
  if (['SETTINGS_BODY_TIMEOUT'].includes(error?.code)) return 408;
  return 500;
}

export function registerPreferencesRoutes(webServer, { store, selfCheck }) {
  const route = webServer.register({
    kind: 'prefix',
    path: '/orbat-agent',
    async handler(req, res) {
      const pathname = new URL(req.url || '/', 'http://localhost').pathname;
      const method = String(req.method || 'GET').toUpperCase();
      if (!isLocalRequest(req)) {
        sendJson(res, 403, { ok: false, error: 'Local DSH request required.' });
        return;
      }
      try {
        if (pathname === '/orbat-agent/settings' && method === 'GET') {
          sendJson(res, 200, {
            ok: true,
            settings: await store.read(),
            defaultOutputDirectory: store.getDefaultOutputDirectory?.() ?? getDefaultOutputDirectory(),
          });
          return;
        }
        if (pathname === '/orbat-agent/settings' && method === 'PUT') {
          const patch = await readJsonBody(req);
          sendJson(res, 200, {
            ok: true,
            settings: await store.update(patch),
            defaultOutputDirectory: store.getDefaultOutputDirectory?.() ?? getDefaultOutputDirectory(),
          });
          return;
        }
        if (pathname === '/orbat-agent/selfcheck' && method === 'POST') {
          await readJsonBody(req);
          const controller = new AbortController();
          res.once('close', () => {
            if (!res.writableEnded) controller.abort();
          });
          const result = await selfCheck({ signal: controller.signal });
          sendJson(res, result.success ? 200 : 503, { ok: result.success, result });
          return;
        }
        if (pathname.startsWith('/orbat-agent/')) {
          sendJson(res, 405, { ok: false, error: 'Unsupported ORBAT settings method or route.' });
          return;
        }
        sendJson(res, 404, { ok: false, error: 'ORBAT settings route not found.' });
      } catch (error) {
        sendJson(res, statusFor(error), { ok: false, error: String(error?.message || error).slice(0, 1_000), code: error?.code || 'SETTINGS_ERROR' });
      }
    },
  });
  return typeof route === 'function' ? route : () => {};
}
