import { randomBytes } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  ensureNodeRuntime,
  NodeRuntimeError,
  parseNodeVersion,
} from './node_runtime.js';

export const MAX_INPUT_BYTES = 10 * 1024 * 1024;
export const MAX_ISSUES_RETURNED = 50;
const MAX_STDOUT_BYTES = 24 * 1024 * 1024;
const MAX_STDERR_BYTES = 256 * 1024;
const MAX_RENDER_FILE_BYTES = 128 * 1024 * 1024;
const SELF_CHECK_TREE = Object.freeze({
  commandLevels: '1',
  options: {
    sidc: '130310002111000000000000000000',
    uniqueDesignation: 'Smoke Div',
    additionalInformation: '',
    dashed: false,
    outline: false,
    'plain-text-mode': false,
    showMapLabels: true,
  },
  subOrganizations: [
    {
      options: {
        sidc: '130310001612110000000000000000',
        uniqueDesignation: '1st Bn',
        additionalInformation: '',
        dashed: false,
        outline: false,
        'plain-text-mode': false,
        showMapLabels: true,
      },
      subOrganizations: [],
    },
    {
      options: {
        sidc: '130310001513030000000000000000',
        uniqueDesignation: 'Arty Coy',
        additionalInformation: '',
        dashed: false,
        outline: false,
        'plain-text-mode': false,
        showMapLabels: true,
      },
      subOrganizations: [],
    },
  ],
});
const RENDER_DEADLINE_MS = 6 * 60 * 1000;
const VALIDATE_DEADLINE_MS = 60 * 1000;

export class OrbatCliError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'OrbatCliError';
    this.code = code;
  }
}

export function sanitizeOutputName(value) {
  let name = String(value ?? 'orbat-chart')
    .normalize('NFC')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_')
    .replace(/[. ]+$/g, '')
    .trim()
    .replace(/\s+/g, '-');
  name = name.slice(0, 56).replace(/[. ]+$/g, '');
  if (!name) name = 'chart';
  // The fixed prefix prevents Windows device names (CON, NUL, COM1, etc.).
  return `orbat-${name}`;
}

/**
 * Decide where a render may write, in priority order:
 * explicit plugin setting, the current session workspace, then legacy user folders.
 * The workspace folder keeps sandboxed sessions writable without a permission prompt.
 * @param {object} input
 * @param {{outputDirectory?: string}} [input.settings]
 * @param {string} [input.workspaceDirectory] absolute session cwd
 * @param {string} [input.preferredOutput] legacy Documents folder
 * @param {string} [input.fallbackOutput] private plugin Output folder
 * @returns {string[]} absolute base directories, de-duplicated
 */
export function resolveOutputBases({
  settings = {},
  workspaceDirectory = '',
  preferredOutput = '',
  fallbackOutput = '',
} = {}) {
  const configured = typeof settings.outputDirectory === 'string' ? settings.outputDirectory.trim() : '';
  if (configured) return [path.resolve(configured)];
  const bases = [];
  if (typeof workspaceDirectory === 'string' && path.isAbsolute(workspaceDirectory)) {
    bases.push(path.join(workspaceDirectory, '编制插件产物仓库'));
  }
  if (preferredOutput) bases.push(preferredOutput);
  if (fallbackOutput) bases.push(fallbackOutput);
  return [...new Set(bases.map((base) => path.resolve(base)))];
}

/**
 * Resolve a tool input that may carry inline JSON or a file path.
 * Paths are absolute, or relative to the live session workspace. Reading the
 * file here (rather than in the model) is the whole point: the model can pass a
 * 12 KB path instead of pasting the same 12 KB JSON into validate and render.
 * @param {string|{json?: string, path?: string, workspaceDirectory?: string}} input
 * @param {{signal?: AbortSignal}} [options]
 * @returns {Promise<{json: string, sourcePath: string}>}
 */
export async function readInputText(input, { signal } = {}) {
  signal?.throwIfAborted();
  if (typeof input === 'string') {
    assertJsonText(input);
    return { json: input, sourcePath: '' };
  }
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new OrbatCliError('INPUT_EMPTY', 'Provide ORBAT JSON text or a JSON file path.');
  }
  const hasJson = typeof input.json === 'string' && input.json.length > 0;
  const hasPath = typeof input.path === 'string' && input.path.trim().length > 0;
  if (hasJson === hasPath) {
    throw new OrbatCliError('INPUT_AMBIGUOUS', 'Provide exactly one of json or path.');
  }
  if (hasJson) {
    assertJsonText(input.json);
    return { json: input.json, sourcePath: '' };
  }

  const rawPath = input.path.trim();
  let filePath;
  if (path.isAbsolute(rawPath)) {
    filePath = path.resolve(rawPath);
  } else {
    const workspace = typeof input.workspaceDirectory === 'string' ? input.workspaceDirectory : '';
    if (!path.isAbsolute(workspace)) {
      throw new OrbatCliError('INPUT_PATH_INVALID', 'A relative path needs an absolute session workspace.');
    }
    filePath = path.resolve(workspace, rawPath);
  }

  let info;
  try {
    info = await stat(filePath);
  } catch (cause) {
    throw new OrbatCliError('INPUT_PATH_NOT_FOUND', `ORBAT JSON file not found: ${filePath}`, { cause });
  }
  if (!info.isFile()) {
    throw new OrbatCliError('INPUT_PATH_NOT_FILE', `Not a regular ORBAT JSON file: ${filePath}`);
  }
  if (info.size > MAX_INPUT_BYTES) {
    throw new OrbatCliError('INPUT_TOO_LARGE', `ORBAT JSON exceeds ${MAX_INPUT_BYTES} bytes.`);
  }
  let text;
  try {
    text = await readFile(filePath, 'utf8');
  } catch (cause) {
    throw new OrbatCliError('INPUT_PATH_INVALID', `Could not read ORBAT JSON file: ${filePath}`, { cause });
  }
  signal?.throwIfAborted();
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  assertJsonText(text);
  return { json: text, sourcePath: filePath };
}

function assertJsonText(json) {
  if (typeof json !== 'string' || Buffer.byteLength(json, 'utf8') === 0) {
    throw new OrbatCliError('INPUT_EMPTY', 'Provide the complete ORBAT JSON as a non-empty string.');
  }
  if (Buffer.byteLength(json, 'utf8') > MAX_INPUT_BYTES) {
    throw new OrbatCliError('INPUT_TOO_LARGE', `ORBAT JSON exceeds ${MAX_INPUT_BYTES} bytes.`);
  }
}

export function parseCliEnvelope(stdout, expectedCommand) {
  if (typeof stdout !== 'string' || stdout.length === 0) {
    throw new OrbatCliError('CLI_EMPTY_OUTPUT', 'ORBAT CLI returned no JSON on stdout.');
  }
  let value;
  try {
    value = JSON.parse(stdout);
  } catch (cause) {
    throw new OrbatCliError('CLI_INVALID_JSON', 'ORBAT CLI stdout was not one valid JSON object.', { cause });
  }
  if (!value || typeof value !== 'object' || Array.isArray(value) || value.command !== expectedCommand) {
    throw new OrbatCliError('CLI_INVALID_ENVELOPE', `Unexpected ORBAT CLI ${expectedCommand} response.`);
  }
  return value;
}

function valueText(value, maxLength = 4_000) {
  if (typeof value !== 'string') return '';
  return value.length > maxLength ? `${value.slice(0, maxLength)}…[truncated]` : value;
}

function outcomeText(handle, streamName) {
  const read = handle.collected?.[streamName]?.readFrom(0);
  if (!read) return { text: '', truncated: false };
  return { text: read.text, truncated: Boolean(read.lossy) };
}

function timeoutSignal(ms) {
  return AbortSignal.timeout(ms);
}

function raceWithControl(done, signal, timeoutMs) {
  return new Promise((resolve) => {
    let finished = false;
    let timer;
    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      resolve(result);
    };
    const onAbort = () => finish({ kind: 'cancelled' });
    timer = setTimeout(() => finish({ kind: 'timeout' }), timeoutMs);
    if (signal?.aborted) {
      finish({ kind: 'cancelled' });
    } else {
      signal?.addEventListener('abort', onAbort, { once: true });
    }
    done.then(
      (outcome) => finish({ kind: 'done', outcome }),
      (error) => finish({ kind: 'failed', error }),
    );
  });
}

function waitForDone(done, ms) {
  return new Promise((resolve) => {
    let finished = false;
    const timer = setTimeout(() => {
      if (finished) return;
      finished = true;
      resolve({ kind: 'timeout' });
    }, ms);
    done.then(
      (outcome) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        resolve({ kind: 'done', outcome });
      },
      (error) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        resolve({ kind: 'failed', error });
      },
    );
  });
}

function requestCooperativeShutdown(handle) {
  const input = handle.stdin;
  if (!input || input.destroyed || input.writableEnded) return false;
  try {
    return input.write('ORBAT_SHUTDOWN\n');
  } catch {
    return false;
  }
}

async function ensureQuiescent(handle) {
  try {
    const quiet = await handle.waitForExit(timeoutSignal(10_000));
    if (quiet) return;
  } catch {
    // Try the provider's range termination before reporting the failed wait.
  }
  handle.terminate();
  let quiet = false;
  try {
    quiet = await handle.waitForExit(timeoutSignal(5_000));
  } catch (cause) {
    throw new OrbatCliError('PROCESS_RANGE_UNKNOWN', 'Could not verify that the ORBAT CLI process tree stopped.', { cause });
  }
  if (!quiet) {
    throw new OrbatCliError('PROCESS_RANGE_STILL_ACTIVE', 'The ORBAT CLI process tree is still active after termination.');
  }
}

/**
 * Execute a fully specified managed subprocess and wait for its entire range.
 * Render cancellation is cooperative over stdin first; validation is terminated
 * directly because it has no browser/profile cleanup to perform.
 */
export async function runManagedCli(subprocess, request, { signal, cancelable = false, timeoutMs }) {
  if (signal?.aborted) signal.throwIfAborted();
  let handle;
  try {
    handle = subprocess.spawn(request);
  } catch (cause) {
    throw new OrbatCliError('CLI_SPAWN_FAILED', `Could not start ORBAT CLI: ${cause?.message ?? cause}`, { cause });
  }

  const done = Promise.resolve(handle.done);
  let first = await raceWithControl(done, signal, timeoutMs);
  let interrupted = first.kind === 'cancelled' || first.kind === 'timeout';
  if (interrupted) {
    if (cancelable) requestCooperativeShutdown(handle);
    else handle.terminate();
    first = await waitForDone(done, cancelable ? 12_000 : 5_000);
    if (first.kind === 'timeout') {
      handle.terminate();
      first = await waitForDone(done, 5_000);
    }
  }

  if (first.kind === 'failed') {
    try {
      handle.terminate();
      await ensureQuiescent(handle);
    } catch {
      // Preserve the original spawn/provider failure below.
    }
    throw new OrbatCliError('CLI_PROCESS_FAILED', `ORBAT CLI process failed: ${first.error?.message ?? first.error}`, { cause: first.error });
  }
  if (first.kind !== 'done') {
    handle.terminate();
    try {
      await ensureQuiescent(handle);
    } catch (cause) {
      throw cause;
    }
    if (signal?.aborted) signal.throwIfAborted();
    return { timedOut: true, outcome: null, stdout: '', stderr: '' };
  }

  let quiet = false;
  try {
    quiet = await handle.waitForExit(timeoutSignal(10_000));
  } catch {
    handle.terminate();
  }
  if (!quiet) await ensureQuiescent(handle);

  if (signal?.aborted) signal.throwIfAborted();
  const stdout = outcomeText(handle, 'stdout');
  const stderr = outcomeText(handle, 'stderr');
  if (stdout.truncated) {
    throw new OrbatCliError('CLI_OUTPUT_TRUNCATED', 'ORBAT CLI stdout exceeded its safe collection limit.');
  }
  return {
    timedOut: interrupted && first.kind === 'done',
    outcome: first.outcome,
    stdout: stdout.text,
    stderr: stderr.text,
    stderrTruncated: stderr.truncated,
  };
}

function isInside(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

async function assertWritable(directory) {
  await mkdir(directory, { recursive: true });
  const probe = path.join(directory, `.orbat-probe-${randomBytes(6).toString('hex')}`);
  await writeFile(probe, 'ok', { flag: 'wx' });
  await rm(probe, { force: true });
}

function boundedIssues(data) {
  const all = Array.isArray(data?.issues) ? data.issues : [];
  const issues = all.slice(0, MAX_ISSUES_RETURNED).map((issue) => ({
    level: valueText(issue?.level, 40),
    path: valueText(issue?.path, 512),
    message: valueText(issue?.message, 1_000),
  }));
  return { issues, issueCount: all.length, issuesTruncated: all.length > issues.length };
}

function envForCli(parentEnv, appData, scratch, outputDir, settings = {}) {
  const env = {};
  for (const name of [
    'PATH', 'USERPROFILE', 'LOCALAPPDATA', 'SYSTEMROOT', 'WINDIR', 'ProgramFiles', 'ProgramFiles(x86)',
    'ComSpec', 'HOMEDRIVE', 'HOMEPATH', 'OS', 'PATHEXT', 'SystemDrive', 'ProgramData',
    'ALLUSERSPROFILE', 'PUBLIC', 'COMPUTERNAME', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE',
    'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'CommonProgramFiles',
    'CommonProgramFiles(x86)', 'ProgramW6432',
  ]) {
    if (typeof parentEnv[name] === 'string' && parentEnv[name].length > 0) env[name] = parentEnv[name];
  }
  env.APPDATA = appData;
  env.TEMP = scratch;
  env.TMP = scratch;
  env.ORBAT_WORK_DIR = scratch;
  env.ORBAT_OUTPUT_DIR = outputDir;
  env.ORBAT_QUIET = '1';
  env.ORBAT_WHITE_BG = settings.whiteBackground === false ? '0' : '1';
  return env;
}

async function probeNodeVersion(candidate, { subprocess, packageRoot, parentEnv, appData, scratchRoot, signal }) {
  const info = await stat(candidate).catch(() => null);
  if (!info?.isFile()) return null;
  try {
    const result = await runManagedCli(subprocess, {
      argv: [candidate, '--version'],
      cwd: packageRoot,
      stdio: {
        stdin: 'ignore',
        stdout: { maxBytes: 1_024 },
        stderr: { maxBytes: 1_024 },
      },
      graceMs: 1_000,
      env: envForCli(parentEnv, appData, scratchRoot, scratchRoot),
    }, { signal, timeoutMs: 10_000 });
    if (result.timedOut || result.outcome?.exitCode !== 0) return null;
    return parseNodeVersion(result.stdout.trim());
  } catch (error) {
    if (signal?.aborted) signal.throwIfAborted();
    return null;
  }
}

async function resolveNodeExecutable({ subprocess, parentEnv, packageRoot, appData, scratchRoot, signal }) {
  const candidates = [];
  for (const base of [parentEnv.ProgramFiles, parentEnv['ProgramFiles(x86)']]) {
    if (typeof base === 'string' && base.length > 0) candidates.push(path.join(base, 'nodejs', 'node.exe'));
  }
  if (typeof parentEnv.LOCALAPPDATA === 'string' && parentEnv.LOCALAPPDATA.length > 0) {
    candidates.push(path.join(parentEnv.LOCALAPPDATA, 'Programs', 'nodejs', 'node.exe'));
  }
  const pathEntries = String(parentEnv.PATH ?? '').slice(0, 32_768).split(path.delimiter).slice(0, 32);
  for (const directory of pathEntries) {
    if (path.isAbsolute(directory)) candidates.push(path.join(directory, 'node.exe'));
  }
  candidates.push('C:\\Program Files\\nodejs\\node.exe', 'C:\\Program Files (x86)\\nodejs\\node.exe');

  for (const candidate of [...new Set(candidates)]) {
    signal?.throwIfAborted();
    const version = await probeNodeVersion(candidate, {
      subprocess,
      packageRoot,
      parentEnv,
      appData,
      scratchRoot,
      signal,
    });
    if (version && version.major >= 24) return { path: candidate, version: version.version };
  }

  const profile = parentEnv.USERPROFILE || os.homedir();
  const localAppData = parentEnv.LOCALAPPDATA || path.join(profile, 'AppData', 'Local');
  try {
    const executable = await ensureNodeRuntime({
      localAppData,
      signal,
      fetchImpl: globalThis.fetch,
      validateExecutable: async (candidate, { signal: runtimeSignal } = {}) => {
        const version = await probeNodeVersion(candidate, {
          subprocess,
          packageRoot,
          parentEnv,
          appData,
          scratchRoot,
          signal: runtimeSignal,
        });
        return version?.version ?? null;
      },
    });
    const version = await probeNodeVersion(executable, {
      subprocess, packageRoot, parentEnv, appData, scratchRoot, signal,
    });
    if (!version || version.major < 24) {
      throw new OrbatCliError('NODE_VERSION_MISMATCH', 'The prepared Node.js runtime did not report a compatible version.');
    }
    return { path: executable, version: version.version };
  } catch (cause) {
    if (signal?.aborted) signal.throwIfAborted();
    if (cause instanceof NodeRuntimeError || typeof cause?.code === 'string') {
      throw new OrbatCliError(cause.code, cause.message, { cause });
    }
    throw new OrbatCliError('NODE_PROVISION_FAILED', `Could not prepare a compatible Node.js runtime: ${cause?.message ?? cause}`, { cause });
  }
}

export function createOrbatCli({
  subprocess,
  packageRoot,
  cliPath = path.join(packageRoot, 'orbat-cli.exe'),
  env = process.env,
  settingsProvider = async () => ({ whiteBackground: true, outputDirectory: '' }),
}) {
  if (!subprocess || typeof subprocess.spawn !== 'function') {
    throw new OrbatCliError('SUBPROCESS_UNAVAILABLE', 'The DSH subprocess service is unavailable.');
  }
  const root = path.resolve(packageRoot);
  const executable = path.resolve(cliPath);
  const profile = env.USERPROFILE || os.homedir();
  const localAppData = env.LOCALAPPDATA || path.join(profile, 'AppData', 'Local');
  const privateRoot = path.join(localAppData, 'OrbatGeneratorDshPlugin');
  const appData = path.join(privateRoot, 'AppData');
  const scratchRoot = path.join(privateRoot, 'Temp');
  const isolatedOutput = path.join(privateRoot, 'Output');
  const preferredOutput = path.join(profile, 'Documents', 'ORBAT Generator');
  const fallbackOutput = isolatedOutput;

  async function validateInput(input, signal) {
    const { json } = await readInputText(input, { signal });
    return validateJsonText(json, signal);
  }

  async function validateJsonText(json, signal) {
    const result = await runJsonCommand('validate', json, { signal });
    if (result.timedOut) return { success: false, valid: false, error: 'Validation timed out.' };
    const envelope = parseCliEnvelope(result.stdout, 'validate');
    const data = envelope.data && typeof envelope.data === 'object' ? envelope.data : {};
    if (result.outcome.exitCode !== 0 && result.outcome.exitCode !== 3) {
      const stderr = summarizeStderr(result.stderr, result.stderrTruncated);
      return { success: false, valid: false, error: valueText(envelope.error) || valueText(stderr) || `CLI exit ${result.outcome.exitCode}.` };
    }
    const { issues, issueCount, issuesTruncated } = boundedIssues(data);
    const redCount = Number.isInteger(data.redCount) ? data.redCount : 0;
    return {
      success: true,
      valid: data.ok === true && redCount === 0,
      nodeCount: Number.isInteger(data.nodeCount) ? data.nodeCount : 0,
      depth: Number.isInteger(data.depth) ? data.depth : 0,
      redCount,
      warnCount: Number.isInteger(data.warnCount) ? data.warnCount : 0,
      issueCount,
      issuesTruncated,
      issues,
    };
  }

  async function normalizeForRender(json, signal) {
    const result = await runJsonCommand('normalize', json, { signal });
    if (result.timedOut) {
      throw new OrbatCliError('NORMALIZE_TIMEOUT', 'Timed out while preparing normalized render input.');
    }
    const envelope = parseCliEnvelope(result.stdout, 'normalize');
    if (result.outcome.exitCode !== 0 || envelope.ok !== true) {
      throw new OrbatCliError(
        'NORMALIZE_FAILED',
        valueText(envelope.error) || summarizeStderr(result.stderr, result.stderrTruncated) || 'Could not normalize ORBAT JSON for rendering.',
      );
    }
    const normalized = envelope.data?.json;
    if (!normalized || typeof normalized !== 'object' || Array.isArray(normalized)) {
      throw new OrbatCliError('NORMALIZE_INVALID_RESULT', 'The CLI did not return a normalized ORBAT object.');
    }
    const text = JSON.stringify(normalized);
    if (Buffer.byteLength(text, 'utf8') > MAX_INPUT_BYTES) {
      throw new OrbatCliError('NORMALIZED_INPUT_TOO_LARGE', 'Normalized ORBAT JSON exceeds the 10 MiB limit.');
    }
    return text;
  }

  async function render(input, { name = 'chart', signal, workspaceDirectory = '' } = {}) {
    const { json } = await readInputText(input, { signal });
    const checked = await validateJsonText(json, signal);
    if (!checked.success) return { ...checked, rendered: false };
    if (!checked.valid) return { ...checked, rendered: false };

    const settings = await settingsProvider();
    const normalizedJson = await normalizeForRender(json, signal);
    const outputDir = await createOutputDirectory(name, settings, workspaceDirectory);
    const outputBase = path.join(outputDir.path, sanitizeOutputName(name));
    let keepOutput = false;
    try {
      const result = await runJsonCommand('render', normalizedJson, {
        signal,
        render: true,
        outputBase,
        outputDirectory: outputDir.path,
        settings,
      });
      if (result.timedOut) {
        return { success: false, valid: true, rendered: false, error: 'Rendering timed out; the browser cleanup request was sent.' };
      }

      if (result.outcome.exitCode !== 0) {
        const stderr = summarizeStderr(result.stderr, result.stderrTruncated);
        const stdoutTail = valueText(result.stdout.slice(-4_000));
        return {
          success: false,
          valid: true,
          rendered: false,
          error: valueText(stderr) || stdoutTail || `Renderer exit ${result.outcome.exitCode}.`,
        };
      }

      const resolvedBase = path.resolve(outputBase);
      const pngPath = await verifiedOutput(`${resolvedBase}.png`, outputDir.path, 'PNG');
      const svgPath = await verifiedOutput(`${resolvedBase}.svg`, outputDir.path, 'SVG');
      keepOutput = true;
      return {
        success: true,
        valid: true,
        rendered: true,
        nodeCount: checked.nodeCount,
        nodeVersion: result.nodeVersion,
        outputDirectory: outputDir.path,
        baseOutputDirectory: outputDir.basePath,
        pngPath,
        ...(svgPath ? { svgPath } : {}),
        issues: checked.issues,
        issueCount: checked.issueCount,
        issuesTruncated: checked.issuesTruncated,
      };
    } finally {
      if (!keepOutput) await rm(outputDir.path, { recursive: true, force: true });
    }
  }

  async function selfCheck({ signal } = {}) {
    const startedAt = Date.now();
    let rendered;
    let cleanupSucceeded = true;
    let settings;
    try {
      settings = await settingsProvider();
      rendered = await render(JSON.stringify(SELF_CHECK_TREE), { name: 'workflow-self-check', signal });
      if (rendered.outputDirectory) {
        try {
          await rm(rendered.outputDirectory, { recursive: true, force: true });
        } catch {
          cleanupSucceeded = false;
        }
      }
      const success = rendered.rendered === true && cleanupSucceeded;
      const checks = [
        { name: 'Settings / 设置', passed: true, detail: 'Preferences loaded / 设置读取成功' },
        { name: 'Validation / 校验', passed: rendered.success === true && rendered.valid === true, detail: `${rendered.nodeCount ?? 0} nodes / ${rendered.nodeCount ?? 0} 个单位` },
        { name: 'Node + browser renderer / Node 与浏览器渲染', passed: rendered.rendered === true, detail: rendered.nodeVersion ? `Node ${rendered.nodeVersion}` : (rendered.error ?? 'No render result / 无渲染结果') },
        { name: 'Temporary output cleanup / 临时文件清理', passed: cleanupSucceeded, detail: cleanupSucceeded ? 'Clean / 已清理' : 'Cleanup failed / 清理失败' },
      ];
      return {
        success,
        rendered: rendered.rendered === true,
        nodeCount: rendered.nodeCount ?? 0,
        nodeVersion: rendered.nodeVersion ?? '',
        elapsedMs: Date.now() - startedAt,
        outputDirectory: rendered.baseOutputDirectory || settings.outputDirectory || preferredOutput,
        checks,
        ...(rendered.error ? { error: valueText(rendered.error, 1_000) } : {}),
        summary: success
          ? `工作流自检通过：校验、Node/浏览器出图与清理均正常。 / Workflow check passed: validation, Node/browser rendering and cleanup are healthy.`
          : `工作流自检失败：${rendered.error ?? (cleanupSucceeded ? 'Render failed.' : 'Temporary output cleanup failed.')} / Workflow self-check failed: ${rendered.error ?? (cleanupSucceeded ? 'render failed' : 'temporary output cleanup failed')}.`,
      };
    } catch (error) {
      if (signal?.aborted) signal.throwIfAborted();
      return {
        success: false,
        rendered: false,
        nodeCount: 0,
        nodeVersion: '',
        elapsedMs: Date.now() - startedAt,
        outputDirectory: settings?.outputDirectory || preferredOutput,
        checks: [
          { name: 'Workflow / 工作流', passed: false, detail: valueText(error?.message ?? String(error), 1_000) },
        ],
        error: valueText(error?.message ?? String(error), 1_000),
        summary: `工作流自检失败：${valueText(error?.message ?? String(error), 1_000)} / Workflow self-check failed: ${valueText(error?.message ?? String(error), 1_000)}`,
      };
    }
  }

  async function runJsonCommand(command, json, { signal, render = false, outputBase, outputDirectory, settings } = {}) {
    if (process.platform !== 'win32') {
      throw new OrbatCliError('PLATFORM_UNSUPPORTED', 'This packaged ORBAT CLI is currently supported on Windows only.');
    }
    const exeInfo = await stat(executable).catch(() => null);
    if (!exeInfo?.isFile()) {
      throw new OrbatCliError('CLI_NOT_FOUND', `Bundled ORBAT CLI not found: ${executable}`);
    }
    const runtimeScripts = ['render_orbat.js', 'cdp.js'].map((name) => path.join(root, 'runtime', name));
    if (render) {
      for (const script of runtimeScripts) {
        if (!(await stat(script).then((info) => info.isFile()).catch(() => false))) {
          throw new OrbatCliError('RENDER_RUNTIME_MISSING', `The plugin package is missing runtime/${path.basename(script)}.`);
        }
      }
    }

    await mkdir(scratchRoot, { recursive: true });
    const work = await mkdtemp(path.join(scratchRoot, 'orbat-input-'));
    const inputPath = path.join(work, 'input.json');
    try {
      await writeFile(inputPath, json, { encoding: 'utf8', flag: 'wx' });
      const nodeRuntime = render ? await resolveNodeExecutable({
        subprocess,
        parentEnv: env,
        packageRoot: root,
        appData,
        scratchRoot,
        signal,
      }) : null;
      const argv = render
        ? [nodeRuntime.path, runtimeScripts[0], inputPath, outputBase]
        : [
            executable,
            command,
            inputPath,
            ...(command === 'normalize' ? ['--adapt-for-render'] : []),
          ];
      const request = {
        argv,
        cwd: root,
        stdio: {
          stdin: 'pipe',
          stdout: { maxBytes: MAX_STDOUT_BYTES },
          stderr: { maxBytes: MAX_STDERR_BYTES },
        },
        graceMs: 5_000,
        env: envForCli(env, appData, scratchRoot, outputDirectory || isolatedOutput, settings),
        ...(render ? {} : { signal }),
      };
      const result = await runManagedCli(subprocess, request, {
        signal,
        cancelable: render,
        timeoutMs: render ? RENDER_DEADLINE_MS : VALIDATE_DEADLINE_MS,
      });
      return render ? { ...result, nodeVersion: nodeRuntime.version } : result;
    } finally {
      await rm(work, { recursive: true, force: true });
    }
  }

  async function createOutputDirectory(name, settings = {}, workspaceDirectory = '') {
    const configured = typeof settings.outputDirectory === 'string' ? settings.outputDirectory.trim() : '';
    const candidates = resolveOutputBases({
      settings,
      workspaceDirectory,
      preferredOutput,
      fallbackOutput,
    });
    let lastError;
    for (const base of candidates) {
      try {
        await assertWritable(base);
        const timestamp = new Date().toISOString().replace(/[-:.TZ]/g, '');
        const dir = path.join(base, `${sanitizeOutputName(name)}-${timestamp}-${randomBytes(4).toString('hex')}`);
        await mkdir(dir, { recursive: false });
        return { path: dir, basePath: base };
      } catch (error) {
        lastError = error;
      }
    }
    const target = configured
      ? `configured directory ${configured}`
      : workspaceDirectory
        ? `session workspace or legacy user folders`
        : 'Documents or LocalAppData';
    throw new OrbatCliError('OUTPUT_DIRECTORY_UNAVAILABLE', `Could not create an output directory under ${target}: ${lastError?.message ?? lastError}`, { cause: lastError });
  }

  return Object.freeze({ validate: validateInput, render, selfCheck });
}

async function verifiedOutput(value, outputDir, kind) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new OrbatCliError(`${kind}_MISSING`, `Renderer did not create the expected ${kind} file.`);
  }
  const candidate = path.resolve(value);
  if (!isInside(outputDir, candidate)) {
    throw new OrbatCliError(`${kind}_OUTSIDE_OUTPUT`, `Rendered ${kind} file is outside the per-run output directory.`);
  }
  let info;
  try {
    await access(candidate, fsConstants.R_OK);
    info = await stat(candidate);
  } catch (cause) {
    throw new OrbatCliError(`${kind}_NOT_FOUND`, `Rendered ${kind} file is missing.`, { cause });
  }
  if (!info.isFile() || info.size === 0 || info.size > MAX_RENDER_FILE_BYTES) {
    throw new OrbatCliError(`${kind}_INVALID_FILE`, `Rendered ${kind} file is empty or exceeds the size limit.`);
  }
  return candidate;
}

export function formatToolError(error) {
  if (error instanceof OrbatCliError) return valueText(`${error.code}: ${error.message}`, 2_000);
  return valueText(`ORBAT_TOOL_ERROR: ${error?.message ?? String(error)}`, 2_000);
}

export function summarizeStderr(stderr, truncated = false) {
  const text = String(stderr ?? '').trim();
  // Chromium reliably emits font/glyph and GPU chatter that is unrelated to the
  // render result. Dropping it keeps failure reports inside the useful tail.
  const kept = text
    .split(/\r?\n/)
    .filter((line) => line.trim() && !/Unable to load glyph range|Fontconfig|DevTools listening on|gpu_|GLES|dbus/i.test(line))
    .join('\n');
  const tail = kept.length > 4_000 ? kept.slice(-4_000) : kept;
  return truncated && tail ? `${tail}\n[stderr tail truncated]` : tail;
}

// Keep Node's ambient credentials out of child processes. `envForCli` uses an
// explicit allowlist and never forwards DEEPSEEK_API_KEY or DSH_* values.
