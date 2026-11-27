# ORBAT CLI adapter protocol

Version: ORBAT Generator `0.3.7-beta`; CLI protocol `1`; current implementation target: Windows x64.

This document is the stable seam between the ORBAT CLI/runtime and agent hosts. A host does not need DSH: validate and normalize JSON with the CLI using explicit argument vectors, parse one JSON object from stdout, then pass normalized JSON to the included Node renderer scripts. Implement your own managed-process lifetime and file-delivery behavior. Do not build a shell command string.

## Input limits and data flow

- JSON input is UTF-8 and must be at most 10 MiB. The DSH tools accept inline `json` or a `path` (absolute, or relative to the session workspace); the Host resolves/reads that path once, then writes the text to a unique private temporary file and passes that file path to the CLI.
- JSON commands accept a positional file, `--in <file>`, or stdin. Precedence is `--in` > positional file > stdin; stdin is read only when no file input is present. UTF-8 BOM is stripped. `normalize` may take `--adapt-for-render`. The AOT `render` command consumes `--in <file>` and `--out <output-base>`.
- JSON rendering does not call the AI API and does not require an API key.
- `ORBAT_OUTPUT_DIR` may be set to a host-controlled writable directory to route the CLI's default artifact archive away from the executable folder. Explicit `--out` paths still take precedence for rendering.
- Rendering starts a local Chromium-family browser which opens `https://spatialillusions.com/unitgenerator`; that page receives/imports the JSON. Network access is required and remote retention/processing is not assessed by this plugin.
- The CLI package must include `runtime/render_orbat.js` and `runtime/cdp.js` beside `orbat-cli.exe`. Rendering requires a Node.js >=24 runtime and Chrome or Edge; users do not need a preinstalled Node runtime for the DSH adapter. It first probes system Node candidates; if none is >=24, it downloads the pinned official Node.js v24.22.3 Windows x64 ZIP, verifies SHA-256, and extracts only `node.exe` and `LICENSE` into `%LOCALAPPDATA%\OrbatGeneratorDshPlugin\Node`. It requires no admin rights and does not change `PATH`. Other hosts must provide their own secure runtime provisioning.
- The pinned archive SHA-256 is `e612af99f626ab415ea225af6bce5c971feb448cb5cae250bb1c3fa50c5f7d9f`; the extracted `win-x64/node.exe` is also checked against the official `SHASUMS256.txt` entry. Update both pins only with a reviewed Node release and its official checksum manifest.
- First use without Node 24+ requires network access to `nodejs.org`. This downloads the runtime only; user ORBAT JSON is sent to `spatialillusions.com` only when rendering starts.

## DSH plugin preferences

The DSH bundle adds a **Settings → ORBAT** page for the PNG background and default output directory. Preferences are stored in `%LOCALAPPDATA%\\OrbatGeneratorDshPlugin\\settings.json` and are not part of the portable CLI protocol. The Host adapter passes `ORBAT_WHITE_BG=1` for white PNG output or `0` for a transparent PNG; SVG is always transparent. A configured output directory is used as the base and fails clearly if unavailable rather than falling back elsewhere. The DSH Settings page and `orbat_workflow_self_check` Agent tool call the same Host self-check operation. Other Agent Hosts should provide their own preferences and self-check UI/operation.

## Version discovery

```text
orbat-cli.exe --version
```

Returns one JSON envelope:

```json
{"ok":true,"command":"version","data":{"version":"0.3.7-beta","protocol":1}}
```

`config` also exposes `data.version` and `data.protocol`, so a host can check compatibility without a separate process. `protocol` increments only when the envelope or field semantics change.

## Commands

### Logs and error reports

```text
orbat-cli.exe logs
orbat-cli.exe logs --tail
orbat-cli.exe logs --errors
```

Returns the log locations. Normal logs live under `%APPDATA%\OrbatGenerator\orbat-logs\` (`app-YYYY-MM-DD.log`), are rotated at 5 MiB and kept for **14 days**. Error reports live separately under `%APPDATA%\OrbatGenerator\orbat-error-reports\` and are **not** auto-deleted. `--tail` adds up to the last 80 normal-log lines; `--errors` lists existing error reports (newest first).

Every successful envelope also carries `data.logs` with `normalDir`, `normalCurrent`, `normalKeepDays`, `errorDir`, and `errorRetention`. Every failure envelope adds a top-level `errorReport` path. The report contains the time, platform, working directory, command tag, message, optional stack, and the normal-log tail, so an agent can read one file instead of app-private internals.

### Validate

```text
orbat-cli.exe validate --in <input.json>
orbat-cli.exe validate <input.json>
cat <input.json> | orbat-cli.exe validate
```

Exit codes:

- `0`: JSON parsed and validation has no red issues.
- `3`: JSON parsed; validation report contains red issues. This is a normal report, not a process crash.
- `1`: parse or execution failure.
- `2`: missing/invalid arguments or input.

Stdout is one JSON envelope:

```json
{"ok":true,"command":"validate","data":{"nodeCount":1,"depth":1,"redCount":0,"warnCount":0,"ok":true,"issues":[]}}
```

`data.issues` items have `level`, `path`, and `message`. The host may truncate the displayed issue list but must retain/report the total count and whether results were truncated.

### Audit (advisory, optional strict gate)

```text
orbat-cli.exe audit <input.json>
orbat-cli.exe audit --strict <input.json>
```

`audit` is read-only: it reports SIDC/name mismatches, duplicate designations, and the validator issue list without changing the source file. By default it exits `0` even when `data.redCount > 0`; callers that trust `data.redCount` should not treat exit `0` as "no red issues". With `--strict` (alias `--fail-on-red`), a red issue makes the process exit `3`; `data.strict` is `true` and `data.passed` is `false`. `data.redCount`, `data.warnCount`, `data.sidcMismatchCount`, and `data.duplicateCount` are always present.

### Normalize for rendering

```text
orbat-cli.exe normalize --in <input.json> --adapt-for-render
```

Exit code `0` returns one JSON envelope whose `data.json` is a normalized ORBAT object. It fills the renderer's seven option keys, adapts display names for the public renderer, and uses `commandLevels: "3"` by default. With `--adapt-for-render` it also applies the name/SIDC echelon safety fix (for composite HQ labels such as `师部及师部营`) before output and reports `data.echelonFixed` (number of corrected nodes). The DSH adapter validates the source first, then writes this normalized object to a fresh temporary JSON file for direct Node rendering. Other hosts should not feed the compact source JSON straight to the page renderer.

`--out <file>` writes the normalized JSON to a file and returns `out`/`chars`; without it, the object is embedded in `data.json`. Source JSON is never modified by this command.

### Render

```text
orbat-cli.exe render --in <input.json> --out <output-base> --cancelable
```

The AOT CLI also exposes this command and returns a JSON envelope on success or failure. On failure the top-level `ok` is `false`, `error` is duplicated at the top level, `data.notices` is still present, and the process exits `1`. On success `data.notices` lists render-only corrections (for example, `渲染前按名称修正 1 处梯队码（仅影响本次渲染，源 JSON 未改）`) and the source JSON is not rewritten. However, on the current Windows test host, Chromium exits with `0x80000003` when launched beneath this AOT process, while the same bundled Node renderer succeeds when started directly. Therefore the DSH adapter and recommended portable host path use this direct runtime invocation after CLI validation:

```text
node.exe runtime/render_orbat.js <normalized-input.json> <output-base>
```

The DSH adapter first calls `normalize <input.json> --adapt-for-render`, saves `data.json` as `<normalized-input.json>`, then launches Node directly. The renderer writes `<output-base>.png` and `<output-base>.svg`; its stdout/stderr are diagnostic streams, not a JSON envelope. A host must check for process exit code `0`, then verify both files are regular, non-empty, size-bounded, and under its per-run output directory before presenting them. Keep the AOT `render` command for other environments only after verifying its browser process chain there.

The DSH adapter runs `validate`, then `normalize --adapt-for-render`, and does not start the renderer if red issues remain. Other hosts should use the same rule unless the user explicitly chooses a different policy.

### Validate-only

```text
orbat-cli.exe render --in <input.json> --validate-only
```

Parses and validates without starting a browser and without writing PNG/SVG. The envelope keeps the validate fields (`redCount/warnCount/ok/issues`) and reports `render.skipped=true, reason="validate-only"`. Exit `3` means red issues; `0` means clean. Use this for fast agent iteration.

### Large-image layout

```text
orbat-cli.exe render --in <input.json> --out <base> --max-width 4096
```

After a successful render, if PNG width exceeds `--max-width` (default 4096), the CLI tries once more with `commandLevels:"2"`, compares widths, and keeps the narrower result. If it is still too wide, it proportionally downscales the PNG to `--max-width` (still one whole image, no pagination). `data.layout` records `commandLevelsInput`, `commandLevelsOutput`, `width`, `height`, `strategy` (`default`/`commandLevels2`/`keep-3`/`downscale`), optional `scale`, and `warning: "建议桌面查看"` when still too wide.

### Batch rescan

```text
orbat-cli.exe batch --dir <images> --out-dir <dir>
orbat-cli.exe batch --dir <images> --validate-only
orbat-cli.exe batch --dir <images> --no-rescan
```

After the initial batch, the CLI rescans the input directory up to two more passes and serially processes images added while the batch was running. Files are deduplicated by absolute path; `data.rescanPasses` records how many extra passes ran. `--no-rescan` disables this. `--validate-only` still runs image recognition (AI key required) and writes the JSON, but skips rendering and reports `render.skipped=true, reason="validate-only"`.

### JSON Schema

```text
orbat-cli.exe schema
orbat-cli.exe schema --out orbat.schema.json
```

Emits or writes the structural contract (`schema/orbat.schema.json`). It covers the root/node shape, root-only `commandLevels`, the seven `options` keys, and a 30-digit `sidc`. Business rules (12 CJK / 20 letters, SIDC semantics, duplicate names) remain in `validate`.

## Cancellation

For direct Node rendering, reserve stdin as a control channel and send exactly one UTF-8 line `ORBAT_SHUTDOWN\n` when the host is cancelled. Allow the renderer to close its browser and remove the temporary profile before terminating the process tree. If it does not exit within a bounded grace period, terminate the managed process range and verify it is quiescent. The DSH adapter uses a 12-second cooperative grace before provider termination. When invoking the AOT `render --in <file> --cancelable` command instead, the CLI forwards the same exact line to Node; do not combine it with `--image`, `--text`, or stdin JSON input.

For validation, which has no browser cleanup, pass the agent cancellation signal to the managed-process provider and terminate promptly.

## Output and security expectations for hosts

- Use fixed executable/argument templates, not shell interpolation.
- Put temporary JSON in a unique directory with restrictive user-only access where the platform supports it; delete it in `finally`.
- Set an explicit environment allowlist and do not forward AI/API credentials.
- Generate output filenames from a sanitized label, not an arbitrary path supplied by the model.
- Write output to a user-writable directory, use a unique per-run folder, and verify outputs remain inside it.
- Cap collected stdout/stderr and model-facing issues/errors. Treat truncated stdout as a protocol failure; do not parse partial JSON.
- Wait for the managed process range to exit, not only the root process.
- This Windows AOT executable is platform-specific; other Agent Hosts can implement the same protocol or build their own CLI for their OS.
