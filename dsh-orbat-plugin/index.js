import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createOrbatCli, formatToolError } from './lib/orbat_cli.js';
import { createPreferencesStore, getDefaultOutputDirectory, registerPreferencesRoutes } from './lib/preferences.js';

export const inject = ['tools', 'subprocess', 'webServer'];

const packageRoot = path.dirname(fileURLToPath(import.meta.url));

const issueSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['level', 'path', 'message'],
  properties: {
    level: { type: 'string' },
    path: { type: 'string' },
    message: { type: 'string' },
  },
};

const outputSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['success', 'summary'],
  properties: {
    success: { type: 'boolean' },
    summary: { type: 'string' },
    valid: { type: 'boolean' },
    rendered: { type: 'boolean' },
    nodeCount: { type: 'integer' },
    depth: { type: 'integer' },
    redCount: { type: 'integer' },
    warnCount: { type: 'integer' },
    issueCount: { type: 'integer' },
    issuesTruncated: { type: 'boolean' },
    issues: { type: 'array', items: issueSchema },
    outputDirectory: { type: 'string' },
    baseOutputDirectory: { type: 'string' },
    workspaceDirectory: { type: 'string' },
    pngPath: { type: 'string' },
    svgPath: { type: 'string' },
    nodeVersion: { type: 'string' },
    elapsedMs: { type: 'integer' },
    checks: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'passed', 'detail'],
        properties: {
          name: { type: 'string' },
          passed: { type: 'boolean' },
          detail: { type: 'string' },
        },
      },
    },
    error: { type: 'string' },
  },
};

const jsonParameters = {
  type: 'object',
  additionalProperties: false,
  properties: {
    json: {
      type: 'string',
      description: 'Complete ORBAT JSON object as text (UTF-8, maximum 10 MiB). Use json or path, not both. / 完整的编制 JSON 文本（UTF-8 最大 10 MiB）；与 path 二选一。',
    },
    path: {
      type: 'string',
      description: 'ORBAT JSON file path: absolute, or relative to the session workspace. Use instead of json to avoid re-emitting a large file. / 编制 JSON 文件路径：绝对路径或相对会话工作区；优先用 path，避免把大 JSON 再输出一遍。',
    },
  },
  anyOf: [{ required: ['json'] }, { required: ['path'] }],
};

const renderParameters = {
  type: 'object',
  additionalProperties: false,
  properties: {
    json: {
      type: 'string',
      description: 'Complete ORBAT JSON object as text (UTF-8, maximum 10 MiB). Use json or path, not both. / 完整的编制 JSON 文本（UTF-8 最大 10 MiB）；与 path 二选一。',
    },
    path: {
      type: 'string',
      description: 'ORBAT JSON file path: absolute, or relative to the session workspace. Use instead of json to avoid re-emitting a large file. / 编制 JSON 文件路径：绝对路径或相对会话工作区；优先用 path，避免把大 JSON 再输出一遍。',
    },
    name: {
      type: 'string',
      description: 'Optional short output title; used only as a filename label, never as a path. / 可选的简短标题，仅作文件名标签，不会作为路径使用。',
    },
  },
  anyOf: [
    { required: ['json'] },
    { required: ['path'] },
  ],
};

const selfCheckParameters = {
  type: 'object',
  additionalProperties: false,
  properties: {},
};

function formatResult(value) {
  // DSH presents rendered content to the model; keep the structured payload
  // compact so indentation does not spend context on every tool call.
  return [{ type: 'text', text: JSON.stringify(value) }];
}

export function workspaceDirectoryOf(exec) {
  const cwd = exec?.agent?.session?.header?.cwd;
  return typeof cwd === 'string' && path.isAbsolute(cwd) ? cwd : '';
}

function assertArguments(args, allowName) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) {
    throw new TypeError('Tool arguments must be a JSON object. / 工具参数必须是 JSON 对象。');
  }
  const allowed = allowName ? new Set(['json', 'path', 'name']) : new Set(['json', 'path']);
  for (const key of Object.keys(args)) {
    if (!allowed.has(key)) throw new TypeError(`Unexpected argument: ${key}. / 不支持的参数：${key}。`);
  }
  const hasJson = args.json !== undefined;
  const hasPath = args.path !== undefined;
  if (hasJson === hasPath) {
    throw new TypeError('Provide exactly one of json or path. / json 与 path 必须二选一。');
  }
  if (hasJson) {
    if (typeof args.json !== 'string' || Buffer.byteLength(args.json, 'utf8') === 0) {
      throw new TypeError('json must be a non-empty string. / json 必须是非空字符串。');
    }
    if (Buffer.byteLength(args.json, 'utf8') > 10 * 1024 * 1024) {
      throw new TypeError('json exceeds the 10 MiB limit. / json 超过 10 MiB 限制。');
    }
  } else {
    if (typeof args.path !== 'string' || args.path.trim().length === 0) {
      throw new TypeError('path must be a non-empty string. / path 必须是非空字符串。');
    }
    if (args.path.length > 32_767 || args.path.includes('\0')) {
      throw new TypeError('path is not a valid file path. / path 不是合法文件路径。');
    }
  }
  if (allowName && args.name !== undefined && typeof args.name !== 'string') {
    throw new TypeError('name must be a string. / name 必须是字符串。');
  }
}

function localizeError(error) {
  const code = typeof error?.code === 'string' ? error.code : 'ORBAT_TOOL_ERROR';
  const zh = {
    CLI_NOT_FOUND: '找不到插件自带的 ORBAT 校验程序。',
    NODE_NOT_FOUND: '找不到 Node.js 24 或更高版本。',
    NODE_DOWNLOAD_FAILED: '无法从 nodejs.org 下载所需的 Node.js；请检查网络或手动安装 Node.js 24+ 后重试。',
    NODE_DOWNLOAD_UNAVAILABLE: '当前 Agent 运行环境不支持通过 HTTPS 下载 Node.js。',
    NODE_ARCHIVE_TOO_LARGE: 'Node.js 下载文件超过安全大小限制，已中止。',
    NODE_CHECKSUM_MISMATCH: 'Node.js SHA-256 校验失败，未安装该文件。',
    NODE_CHECKSUM_INVALID: '插件内置的Node.js SHA-256配置无效。',
    NODE_ARCHIVE_INVALID: 'Node.js ZIP结构或内容校验失败，未安装该文件。',
    NODE_CACHE_UNSAFE: '无法安全使用当前用户的 Node.js 私有安装目录。',
    NODE_VERSION_CHECK_UNAVAILABLE: '当前 Agent Host 无法验证Node.js版本。',
    NODE_VERSION_MISMATCH: '下载的Node.js版本与插件锁定版本不一致。',
    NODE_INSTALL_VERIFY_FAILED: 'Node.js安装后的版本、完整性或许可证文件检查失败。',
    NODE_PROVISION_FAILED: '无法完成Node.js私有安装。',
    NODE_PLATFORM_UNSUPPORTED: '自动安装Node.js目前仅支持Windows x64。',
    PLATFORM_UNSUPPORTED: '此插件版本目前仅支持 Windows。',
    RENDER_RUNTIME_MISSING: '插件包缺少渲染运行文件。',
    OUTPUT_DIRECTORY_UNAVAILABLE: '无法创建输出目录。',
    INPUT_EMPTY: '输入的 JSON 为空。',
    INPUT_TOO_LARGE: '输入的 JSON 超过大小限制。',
    INPUT_AMBIGUOUS: 'json 与 path 只能提供一个。',
    INPUT_PATH_INVALID: '文件路径无效；相对路径需要当前会话工作区。',
    INPUT_PATH_NOT_FOUND: '找不到指定的编制 JSON 文件。',
    INPUT_PATH_NOT_FILE: 'path 指向的不是普通文件。',
    CLI_OUTPUT_TRUNCATED: '校验程序输出过长，已安全中止。',
    SUBPROCESS_UNAVAILABLE: 'DSH 子进程服务不可用。',
  }[code] ?? 'ORBAT 插件执行失败。';
  return `${zh} / ${formatToolError(error)}`;
}

function asToolError(error, signal) {
  if (signal?.aborted || error?.name === 'AbortError') return error;
  return new Error(localizeError(error), { cause: error });
}

function summarizeValidation(result) {
  if (!result.success) {
    const detail = result.error ?? 'unknown CLI error';
    return {
      success: false,
      summary: `无法完成编制校验 / Could not validate the ORBAT input: ${detail}`,
      error: detail,
    };
  }
  const summary = result.valid
    ? `编制结构有效：${result.nodeCount} 个单位，深度 ${result.depth}，${result.warnCount} 条警告。 / Valid ORBAT tree: ${result.nodeCount} nodes, depth ${result.depth}, ${result.warnCount} warning(s).`
    : `暂不能出图：发现 ${result.redCount} 条红牌问题、${result.warnCount} 条警告。请依据 issues 中的路径和说明修正 JSON。 / Not ready to render: ${result.redCount} red issue(s), ${result.warnCount} warning(s). Fix the JSON using the issue paths and messages.`;
  return { ...result, summary };
}

function summarizeRender(result) {
  if (result.rendered) {
    const svg = result.svgPath ? ` SVG: ${result.svgPath}` : '';
    return {
      ...result,
      summary: `已渲染 ${result.nodeCount} 个单位。PNG: ${result.pngPath}.${svg} 请调用 present 工具并传入 pngPath 查看预览。 / Rendered ${result.nodeCount} units. Use the present tool with pngPath to show the preview.`,
    };
  }
  if (result.valid === false && result.success) {
    return {
      ...result,
      summary: `校验发现 ${result.redCount ?? 0} 条红牌问题，已拒绝出图。请修正 JSON 后重试。 / Rendering was refused because validation found ${result.redCount ?? 0} red issue(s). Correct the JSON and retry.`,
    };
  }
  const detail = result.error ?? 'unknown render error';
  return {
    ...result,
    summary: `渲染失败：${detail} / Rendering failed: ${detail}`,
  };
}

function makeTool({ name, description, parameters, allowName = false, allowEmpty = false, timeoutMs, execute }) {
  return {
    name,
    description,
    parameters,
    timeoutMs,
    output: {
      schema: outputSchema,
      render: (_args, value) => formatResult(value),
    },
    async execute(args, exec) {
      if (allowEmpty) {
        if (!args || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).length !== 0) {
          throw new TypeError('This tool takes no arguments. / 此工具不接受参数。');
        }
      } else {
        assertArguments(args, allowName);
      }
      return execute(args, exec);
    },
  };
}

export function apply(ctx) {
  ctx.effect(() => {
    const preferences = createPreferencesStore({
      localAppData: process.env.LOCALAPPDATA,
      userProfile: process.env.USERPROFILE,
    });
    const bridge = createOrbatCli({
      subprocess: ctx.subprocess,
      packageRoot,
      settingsProvider: () => preferences.read(),
    });
    const disposers = [];
    try {
      disposers.push(registerPreferencesRoutes(ctx.webServer, {
        store: preferences,
        selfCheck: (options) => bridge.selfCheck(options),
      }));
      disposers.push(ctx.tools.register(makeTool({
        name: 'orbat_validate_json',
        description: 'Validate a complete ORBAT JSON tree after generating or editing it. Red issues are a normal result; use the returned issue paths/messages to fix the JSON before rendering. / 在生成或修改编制 JSON 后校验完整结构。红牌问题是正常校验结果；请依据返回的问题路径和说明修正 JSON 后再出图。',
        parameters: jsonParameters,
        timeoutMs: 75_000,
        async execute(args, exec) {
          try {
            return summarizeValidation(await bridge.validate({
              json: args.json,
              path: args.path,
              workspaceDirectory: workspaceDirectoryOf(exec),
            }, exec.signal));
          } catch (error) {
            throw asToolError(error, exec.signal);
          }
        },
      })));

      disposers.push(ctx.tools.register(makeTool({
        name: 'orbat_render_json',
        description: 'After validating the complete ORBAT JSON, render it to PNG and SVG. It validates again and refuses any red issue. By default files go to the session workspace subfolder 编制插件产物仓库; an explicit plugin setting overrides that. A successful result returns absolute paths; call the present tool with pngPath. Rendering opens the public spatialillusions.com renderer in a local browser. / 先校验完整编制 JSON，再渲染为 PNG 和 SVG；默认写入当前会话工作区的“编制插件产物仓库”，插件设置里的显式目录优先。成功时返回绝对路径，请调用 present 工具并传入 pngPath 查看。',
        parameters: renderParameters,
        allowName: true,
        timeoutMs: 720_000,
        async execute(args, exec) {
          try {
            const workspaceDirectory = workspaceDirectoryOf(exec);
            const result = summarizeRender(await bridge.render({
              json: args.json,
              path: args.path,
              workspaceDirectory,
            }, {
              name: args.name ?? 'chart',
              signal: exec.signal,
              workspaceDirectory,
            }));
            return {
              ...result,
              workspaceDirectory,
            };
          } catch (error) {
            throw asToolError(error, exec.signal);
          }
        },
      })));

      disposers.push(ctx.tools.register(makeTool({
        name: 'orbat_workflow_self_check',
        description: 'Run the same end-to-end workflow check shown in ORBAT Settings: validate, prepare Node.js if needed, open the browser renderer, create and clean a small smoke output. It does not need an API key. / 执行与 ORBAT 设置面板相同的端到端工作流自检：校验、按需准备 Node.js、打开浏览器渲染器、生成并清理小型冒烟文件。不需要 API Key。',
        parameters: selfCheckParameters,
        allowEmpty: true,
        timeoutMs: 720_000,
        async execute(_args, exec) {
          try {
            return await bridge.selfCheck({ signal: exec.signal });
          } catch (error) {
            throw asToolError(error, exec.signal);
          }
        },
      })));
    } catch (error) {
      for (const dispose of disposers.reverse()) dispose();
      throw error;
    }

    return () => {
      for (const dispose of disposers.reverse()) dispose();
    };
  });
}
