window.__ModuleLoader__.load({
  id: '@local/orbat-agent/client',
  factory: (require) => {
    const React = require('react');

    const NAMESPACE = 'orbat-agent-settings';
    const BASE = '/orbat-agent';
    const DEFAULT_SETTINGS = Object.freeze({ whiteBackground: true, outputDirectory: '' });

    const dictionary = {
      en: {
        nav: 'ORBAT',
        title: 'ORBAT settings',
        intro: 'Choose how PNG files are exported and where this plugin saves rendered files.',
        backgroundTitle: 'PNG background',
        backgroundHelp: 'This option affects PNG output only. SVG files are always transparent.',
        svgAlwaysTransparent: 'SVG exports always keep transparency.',
        currentFolder: 'Currently used folder',
        whiteBackground: 'White background',
        transparentBackground: 'Transparent background',
        outputTitle: 'Default output directory',
        outputHelp: 'Leave this empty to use the default folder. Enter a full Windows path to use another folder.',
        outputPlaceholder: 'C:\\Users\\…\\Documents\\ORBAT Generator',
        defaultFolder: 'Default folder: {path}',
        saveDirectory: 'Save directory',
        useDefault: 'Restore default',
        saved: 'Settings saved.',
        loading: 'Loading settings…',
        saving: 'Saving…',
        loadFailed: 'Could not load ORBAT settings: {error}',
        saveFailed: 'Could not save settings: {error}',
        selfCheckTitle: 'Workflow self-check',
        selfCheckHelp: 'Runs a small validation and browser-render test, then removes its temporary files. It does not require an API key.',
        selfCheckNetwork: 'The check may download the pinned Node.js runtime if needed and opens spatialillusions.com in Chrome or Edge.',
        runSelfCheck: 'Run self-check',
        checking: 'Checking the ORBAT workflow…',
        selfCheckPassed: 'Workflow check passed.',
        selfCheckFailed: 'Workflow check failed.',
        unsavedPath: 'Save the output-directory change before running the check.',
        pass: 'Passed',
        fail: 'Failed',
        close: 'Close settings',
      },
      zh: {
        nav: '编制图',
        title: 'ORBAT 编制图设置',
        intro: '选择 PNG 导出背景，以及本插件保存渲染文件的默认位置。',
        backgroundTitle: 'PNG 背景',
        backgroundHelp: '此选项只影响 PNG；SVG 文件始终为透明背景。',
        svgAlwaysTransparent: 'SVG 导出始终保留透明背景。',
        currentFolder: '当前使用目录',
        whiteBackground: '白色背景',
        transparentBackground: '透明背景',
        outputTitle: '默认输出目录',
        outputHelp: '留空则使用默认目录；如需其他位置，请填写完整的 Windows 路径。',
        outputPlaceholder: 'C:\\Users\\…\\Documents\\ORBAT Generator',
        defaultFolder: '默认目录：{path}',
        saveDirectory: '保存目录',
        useDefault: '恢复默认',
        saved: '设置已保存。',
        loading: '正在读取设置…',
        saving: '正在保存…',
        loadFailed: '无法读取 ORBAT 设置：{error}',
        saveFailed: '无法保存设置：{error}',
        selfCheckTitle: '插件工作流自检',
        selfCheckHelp: '运行小型校验和浏览器出图测试，然后删除临时文件；不需要 API Key。',
        selfCheckNetwork: '如果需要，自检会下载固定版本的 Node.js，并在 Chrome 或 Edge 中打开 spatialillusions.com。',
        runSelfCheck: '运行工作流自检',
        checking: '正在检查 ORBAT 工作流…',
        selfCheckPassed: '工作流自检通过。',
        selfCheckFailed: '工作流自检失败。',
        unsavedPath: '请先保存输出目录的更改，再运行自检。',
        pass: '通过',
        fail: '未通过',
        close: '关闭设置',
      },
    };

    function apiUrl(path) {
      const value = String(path == null ? '' : path);
      if (/^[a-z][a-z0-9+.-]*:/i.test(value)) return value;
      if (value.startsWith(BASE)) return value;
      return BASE + (value.startsWith('/') ? value : `/${value}`);
    }

    async function apiJson(path, { method = 'GET', body, signal } = {}) {
      const response = await fetch(apiUrl(path), {
        method,
        cache: 'no-store',
        ...(signal ? { signal } : {}),
        ...(body === undefined ? {} : {
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        }),
      });
      let payload;
      try {
        payload = await response.json();
      } catch {
        throw new Error(`HTTP ${response.status}: invalid JSON response`);
      }
      if (!response.ok || payload?.ok !== true) {
        const error = new Error(String(payload?.error || `HTTP ${response.status}`));
        error.payload = payload;
        throw error;
      }
      return payload;
    }

    function Panel({ locale }) {
      const subscribe = React.useCallback((listener) => locale.subscribe(listener), [locale]);
      const getSnapshot = React.useCallback(() => locale.getSnapshot(), [locale]);
      React.useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
      const t = locale.bind(NAMESPACE);

      const [settings, setSettings] = React.useState(DEFAULT_SETTINGS);
      const [defaultDirectory, setDefaultDirectory] = React.useState('');
      const [directoryDraft, setDirectoryDraft] = React.useState('');
      const [loading, setLoading] = React.useState(true);
      const [saving, setSaving] = React.useState(false);
      const [checking, setChecking] = React.useState(false);
      const [status, setStatus] = React.useState(null);
      const [checkResult, setCheckResult] = React.useState(null);

      React.useEffect(() => {
        const controller = new AbortController();
        let alive = true;
        apiJson('/settings', { signal: controller.signal }).then((payload) => {
          if (!alive) return;
          const next = payload.settings || DEFAULT_SETTINGS;
          setSettings(next);
          setDirectoryDraft(next.outputDirectory || '');
          setDefaultDirectory(payload.defaultOutputDirectory || '');
          setLoading(false);
        }).catch((error) => {
          if (!alive || error?.name === 'AbortError') return;
          setStatus({ kind: 'error', text: t('loadFailed', { error: String(error.message || error) }) });
          setLoading(false);
        });
        return () => {
          alive = false;
          controller.abort();
        };
      }, [t]);

      const saveSettings = async (patch) => {
        setSaving(true);
        setStatus({ kind: 'busy', text: t('saving') });
        try {
          const payload = await apiJson('/settings', { method: 'PUT', body: patch });
          const next = payload.settings || { ...settings, ...patch };
          setSettings(next);
          setDirectoryDraft(next.outputDirectory || '');
          setDefaultDirectory(payload.defaultOutputDirectory || defaultDirectory);
          setStatus({ kind: 'success', text: t('saved') });
          return true;
        } catch (error) {
          setStatus({ kind: 'error', text: t('saveFailed', { error: String(error.message || error) }) });
          return false;
        } finally {
          setSaving(false);
        }
      };

      const runCheck = async () => {
        if (directoryDraft !== (settings.outputDirectory || '')) return;
        setChecking(true);
        setStatus({ kind: 'busy', text: t('checking') });
        setCheckResult(null);
        try {
          const payload = await apiJson('/selfcheck', { method: 'POST', body: {} });
          setCheckResult(payload.result || null);
          const passed = payload.result?.success === true;
          setStatus({ kind: passed ? 'success' : 'error', text: t(passed ? 'selfCheckPassed' : 'selfCheckFailed') });
        } catch (error) {
          setCheckResult(error?.payload?.result || {
            success: false,
            summary: String(error.message || error),
            checks: [],
          });
          setStatus({ kind: 'error', text: t('selfCheckFailed') });
        } finally {
          setChecking(false);
        }
      };

      const cardStyle = {
        border: '1px solid var(--dsw-alias-border-l2)',
        borderRadius: 'var(--dsw-radius-md, 12px)',
        background: 'var(--dsw-alias-bg-layer-2)',
        padding: '18px 20px',
        display: 'flex',
        flexDirection: 'column',
        gap: 12,
      };
      const titleStyle = { color: 'var(--dsw-alias-label-primary)', fontWeight: 600, fontSize: 14, margin: 0 };
      const helpStyle = { color: 'var(--dsw-alias-label-secondary)', fontSize: 12, lineHeight: 1.55, margin: 0 };
      const buttonStyle = {
        color: 'var(--dsw-alias-label-primary)',
        background: 'var(--dsw-alias-bg-layer-2)',
        border: '1px solid var(--dsw-alias-border-l2)',
        borderRadius: 'var(--dsw-radius-sm, 8px)',
        padding: '8px 12px',
        cursor: 'pointer',
        font: 'inherit',
      };
      const inputStyle = {
        color: 'var(--dsw-alias-label-primary)',
        background: 'var(--dsw-alias-bg-layer-2)',
        border: '1px solid var(--dsw-alias-border-l2)',
        borderRadius: 'var(--dsw-radius-sm, 8px)',
        padding: '9px 11px',
        font: 'inherit',
        width: '100%',
        boxSizing: 'border-box',
      };
      const mutedStyle = { color: 'var(--dsw-alias-label-tertiary)', fontSize: 11, lineHeight: 1.5, margin: 0, overflowWrap: 'anywhere' };
      const savedPath = settings.outputDirectory || defaultDirectory;
      const dirtyDirectory = directoryDraft !== (settings.outputDirectory || '');
      const disabled = loading || saving;

      const h = React.createElement;
      const rootStyle = {
        color: 'var(--dsw-alias-label-primary)',
        fontFamily: 'var(--dsw-font-family)',
        fontSize: 14,
        maxWidth: 820,
        padding: '24px 28px 40px',
        display: 'flex',
        flexDirection: 'column',
        gap: 16,
      };
      const backgroundOptions = [
        { value: true, label: t('whiteBackground') },
        { value: false, label: t('transparentBackground') },
      ];
      const backgroundSection = h('section', { style: cardStyle, 'aria-labelledby': 'orbat-background-title' },
        h('h2', { id: 'orbat-background-title', style: titleStyle }, t('backgroundTitle')),
        h('p', { style: helpStyle }, t('backgroundHelp')),
        h('div', { role: 'radiogroup', 'aria-label': t('backgroundTitle'), style: { display: 'flex', flexWrap: 'wrap', gap: 10 } },
          backgroundOptions.map((option) => h('label', {
            key: String(option.value),
            style: {
              display: 'inline-flex',
              alignItems: 'center',
              gap: 8,
              border: '1px solid var(--dsw-alias-border-l2)',
              borderRadius: 'var(--dsw-radius-sm, 8px)',
              background: 'var(--dsw-alias-bg-layer-2)',
              padding: '9px 12px',
              cursor: disabled ? 'not-allowed' : 'pointer',
              opacity: disabled ? 0.65 : 1,
            },
          },
          h('input', {
            type: 'radio',
            name: 'orbat-png-background',
            value: String(option.value),
            checked: settings.whiteBackground === option.value,
            disabled,
            onChange: () => { void saveSettings({ whiteBackground: option.value }); },
            style: { accentColor: 'var(--dsw-alias-label-primary)' },
          }),
          h('span', null, option.label)))),
        h('p', { style: mutedStyle }, t('svgAlwaysTransparent')),
      );
      const outputSection = h('section', { style: cardStyle, 'aria-labelledby': 'orbat-output-title' },
        h('h2', { id: 'orbat-output-title', style: titleStyle }, t('outputTitle')),
        h('p', { style: helpStyle }, t('outputHelp')),
        h('input', {
          type: 'text',
          value: directoryDraft,
          disabled,
          spellCheck: false,
          autoComplete: 'off',
          placeholder: t('outputPlaceholder'),
          'aria-label': t('outputTitle'),
          onChange: (event) => setDirectoryDraft(event.target.value),
          style: inputStyle,
        }),
        h('p', { style: mutedStyle }, t('defaultFolder', { path: defaultDirectory })),
        h('p', { style: mutedStyle }, `${t('currentFolder')}: ${savedPath}`),
        h('div', { style: { display: 'flex', flexWrap: 'wrap', gap: 8 } },
          h('button', {
            type: 'button',
            disabled: disabled || !dirtyDirectory,
            onClick: () => { void saveSettings({ outputDirectory: directoryDraft }); },
            style: { ...buttonStyle, opacity: disabled || !dirtyDirectory ? 0.55 : 1 },
          }, t('saveDirectory')),
          h('button', {
            type: 'button',
            disabled: disabled || !settings.outputDirectory,
            onClick: () => { setDirectoryDraft(''); void saveSettings({ outputDirectory: '' }); },
            style: { ...buttonStyle, opacity: disabled || !settings.outputDirectory ? 0.55 : 1 },
          }, t('useDefault')),
        ),
      );
      const checkStatus = checkResult ? h('span', {
        role: 'status',
        style: { color: checkResult.success ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-state-error-primary)', fontSize: 12 },
      }, checkResult.success ? t('selfCheckPassed') : t('selfCheckFailed')) : null;
      const checkDetails = checkResult ? h('div', { style: { display: 'flex', flexDirection: 'column', gap: 8 } },
        checkResult.summary ? h('p', { style: helpStyle }, checkResult.summary) : null,
        Array.isArray(checkResult.checks) ? checkResult.checks.map((check, index) => h('div', {
          key: `${check.name || 'check'}-${index}`,
          style: { display: 'grid', gridTemplateColumns: 'minmax(150px, 0.35fr) minmax(0, 1fr)', gap: 12, fontSize: 12 },
        },
        h('span', { style: { color: check.passed ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-state-error-primary)' } }, `${check.passed ? '✓' : '×'} ${check.name || ''}`),
        h('span', { style: helpStyle }, check.detail || ''))) : null,
      ) : null;
      const selfCheckSection = h('section', { style: cardStyle, 'aria-labelledby': 'orbat-check-title' },
        h('h2', { id: 'orbat-check-title', style: titleStyle }, t('selfCheckTitle')),
        h('p', { style: helpStyle }, t('selfCheckHelp')),
        h('p', { style: mutedStyle }, t('selfCheckNetwork')),
        dirtyDirectory ? h('p', { role: 'status', style: mutedStyle }, t('unsavedPath')) : null,
        h('div', { style: { display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' } },
          h('button', {
            type: 'button',
            disabled: loading || saving || checking || dirtyDirectory,
            onClick: runCheck,
            style: { ...buttonStyle, opacity: loading || saving || checking || dirtyDirectory ? 0.55 : 1 },
          }, checking ? t('checking') : t('runSelfCheck')),
          checkStatus,
        ),
        checkDetails,
      );
      const statusNotice = status ? h('p', {
        role: status.kind === 'error' ? 'alert' : 'status',
        'aria-live': 'polite',
        style: {
          color: status.kind === 'error' ? 'var(--dsw-alias-state-error-primary)' : status.kind === 'success' ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-label-secondary)',
          margin: 0,
          fontSize: 12,
        },
      }, status.text) : null;

      return h('div', { style: rootStyle },
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: 6 } },
          h('h1', { style: { ...titleStyle, fontSize: 18 } }, t('title')),
          h('p', { style: helpStyle }, t('intro')),
        ),
        loading ? h('p', { role: 'status', style: helpStyle }, t('loading')) : null,
        backgroundSection,
        outputSection,
        selfCheckSection,
        statusNotice,
      );
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        const t = ctx.locale.bind(NAMESPACE);
        ctx.effect(() => ctx.locale.register(NAMESPACE, dictionary));
        ctx.effect(() => ctx.slots.inject('settings.section', () => {
          const registerSection = () => ctx.slots.register({
            name: 'settings.section',
            id: 'orbat-agent',
            order: 650,
            label: () => t('nav'),
          }, () => React.createElement(Panel, { locale: ctx.locale }));
          let disposeSection = registerSection();
          const disposeLocaleListener = ctx.on('locale/change', () => {
            disposeSection();
            disposeSection = registerSection();
          });
          return () => {
            disposeLocaleListener();
            disposeSection();
          };
        }));
      },
    };
  },
});
