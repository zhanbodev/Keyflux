import { useEffect, useRef, useState } from 'react';
import { command, fixture, loadTheme, type Status } from './bridge';
import { KeyboardPreview, layouts } from './KeyboardPreview';
import {
  defaultTheme,
  labels,
  parseTheme,
  phases,
  sideSignal,
  type Phase,
  type Signal,
  type Theme,
} from './theme';

export function App() {
  const [theme, setTheme] = useState<Theme>(defaultTheme);
  const [saved, setSaved] = useState<Theme>(defaultTheme);
  const [status, setStatus] = useState<Status | null>(null);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState('');
  const [connectionError, setConnectionError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [model, setModel] = useState(layouts[0].id);
  const [phase, setPhase] = useState<Phase>('thinking');
  const [follow, setFollow] = useState(false);
  const [zone, setZone] = useState<'main' | 'side'>('main');
  const generation = useRef(0);
  const dirty = JSON.stringify(theme) !== JSON.stringify(saved);
  useEffect(() => {
    let disposed = false;
    let timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      if (document.visibilityState !== 'hidden') {
        try {
          const next = await command<Status>('get_status');
          if (disposed) return;
          if (!next.result.theme_schema_versions?.includes(2))
            throw new Error('核心不支持 Theme v2，请更新 Zig 核心');
          setStatus(next);
          setConnectionError('');
        } catch (e) {
          if (!disposed) {
            setStatus(null);
            setConnectionError(String(e));
          }
        }
      }
      if (!disposed) timer = setTimeout(refresh, 1500);
    };
    const init = async () => {
      try {
        const [next, loaded] = await Promise.all([command<Status>('get_status'), loadTheme()]);
        if (disposed) return;
        if (!next.result.theme_schema_versions?.includes(2))
          throw new Error('核心不支持 Theme v2，请更新 Zig 核心');
        setStatus(next);
        setTheme(loaded);
        setSaved(structuredClone(loaded));
        setReady(true);
        setConnectionError('');
        timer = setTimeout(refresh, 1500);
      } catch (e) {
        if (!disposed) {
          setConnectionError(String(e));
          timer = setTimeout(init, 3000);
        }
      }
    };
    void init();
    return () => {
      disposed = true;
      clearTimeout(timer);
    };
  }, []);
  // Closing the Tauri settings window destroys this renderer. Zig and the tray
  // stay alive; reopening creates a fresh editor from persisted configuration.
  useEffect(() => {
    const guard = (event: BeforeUnloadEvent) => {
      if (dirty) event.preventDefault();
    };
    window.addEventListener('beforeunload', guard);
    return () => window.removeEventListener('beforeunload', guard);
  }, [dirty]);
  const livePhase = status?.result.state.phase;
  const displayed = follow
    ? phases.includes(livePhase as Phase)
      ? (livePhase as Phase)
      : null
    : phase;
  const editPhase = displayed ?? phase;
  const signal =
    zone === 'main' || theme.side.mode === 'follow_main'
      ? theme.signals[editPhase]
      : theme.side.signals[editPhase];
  const update = (value: Partial<Signal>) =>
    setTheme((previous) => {
      const next = structuredClone(previous);
      Object.assign(
        zone === 'main' ? next.signals[editPhase] : next.side.signals[editPhase],
        value,
      );
      return next;
    });
  const run = async (task: () => Promise<void>) => {
    setBusy(true);
    setNotice('');
    setError('');
    try {
      await task();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };
  const save = () =>
    void run(async () => {
      const validated = parseTheme(theme);
      await command('save_theme', { theme: validated });
      setSaved(structuredClone(validated));
      setError('');
      setNotice('配色已保存');
    });
  // A local selection never pretends to be an agent event. The optional button
  // sends only a short-lived simulated main-light preview through the core.
  const preview = () =>
    void run(async () => {
      await command('preview_main', { signal: theme.signals[editPhase] });
      setNotice('模拟主灯预览 3 秒');
    });
  const sideLocked = zone === 'side' && (!theme.side.enabled || theme.side.mode === 'follow_main');
  return (
    <main>
      <header className="app-header">
        <h1>Keyflux</h1>
        <span className={`connection ${status ? 'online' : ''}`}>
          <i />
          {fixture
            ? '浏览器样例'
            : status
              ? status.result.backend === 'simulated'
                ? '模拟核心'
                : '只读核心'
              : '核心未连接'}
        </span>
      </header>
      <section className="preview-panel">
        <div className="preview-toolbar">
          <select
            aria-label="键盘型号预览"
            value={model}
            onChange={(e) => setModel(e.target.value)}
          >
            {layouts.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name}
                {l.preview_only ? ' · 布局样例' : ''}
              </option>
            ))}
          </select>
          <label className="toggle">
            <input type="checkbox" checked={follow} onChange={(e) => setFollow(e.target.checked)} />
            跟随核心状态
          </label>
        </div>
        <KeyboardPreview
          model={model}
          main={displayed ? theme.signals[displayed] : null}
          side={displayed ? sideSignal(theme, displayed) : null}
          zone={zone}
          onZone={setZone}
        />
        <div className="preview-footer">
          <span>
            {displayed ? labels[displayed] : labels[livePhase === 'idle' ? 'idle' : 'unavailable']}
          </span>
          <span>屏幕预览 · 侧灯位置为示意</span>
        </div>
      </section>
      <section className="editor">
        <div className="editor-heading">
          <div className="tabs" aria-label="灯区">
            <button className={zone === 'main' ? 'active' : ''} onClick={() => setZone('main')}>
              主键区
            </button>
            <button className={zone === 'side' ? 'active' : ''} onClick={() => setZone('side')}>
              侧边灯条
            </button>
          </div>
          <div className="actions">
            <button
              disabled={!ready || busy}
              onClick={() =>
                void run(async () => {
                  const imported = await command<unknown>('import_theme');
                  if (imported !== null) {
                    setTheme(parseTheme(imported));
                    setNotice('已导入，保存后生效');
                  }
                })
              }
            >
              导入
            </button>
            <button
              disabled={!ready || busy}
              onClick={() =>
                void run(async () => {
                  if (await command<boolean>('export_theme', { theme: parseTheme(theme) }))
                    setNotice('配色已导出');
                })
              }
            >
              导出
            </button>
          </div>
        </div>
        {zone === 'side' && (
          <div className="side-settings">
            <label className="toggle">
              <input
                type="checkbox"
                checked={theme.side.enabled}
                onChange={(e) =>
                  setTheme({ ...theme, side: { ...theme.side, enabled: e.target.checked } })
                }
              />
              启用侧灯预览
            </label>
            <select
              aria-label="侧灯配色模式"
              value={theme.side.mode}
              onChange={(e) =>
                setTheme({
                  ...theme,
                  side: { ...theme.side, mode: e.target.value as Theme['side']['mode'] },
                })
              }
            >
              <option value="follow_main">跟随主键区</option>
              <option value="independent">独立配色</option>
            </select>
            <span>硬件写入尚未启用</span>
          </div>
        )}
        <div className="editor-grid">
          <div className="states" aria-label="状态配色">
            {phases.map((p) => {
              const swatch =
                zone === 'main'
                  ? theme.signals[p]
                  : theme.side.mode === 'follow_main'
                    ? theme.signals[p]
                    : theme.side.signals[p];
              return (
                <button
                  key={p}
                  className={editPhase === p ? 'selected' : ''}
                  onClick={() => {
                    setFollow(false);
                    setPhase(p);
                  }}
                >
                  <i style={{ backgroundColor: swatch.color }} />
                  <span>{labels[p]}</span>
                  <code>{swatch.color}</code>
                </button>
              );
            })}
          </div>
          <div className="color-editor">
            <h2>{labels[editPhase]}</h2>
            <fieldset disabled={!ready || busy || sideLocked}>
              <label className="color-control">
                <input
                  type="color"
                  aria-label="状态颜色"
                  value={signal.color}
                  onChange={(e) => update({ color: e.target.value.toUpperCase() })}
                />
                <span>颜色</span>
                <HexField
                  key={`${zone}-${editPhase}-${generation.current}`}
                  value={signal.color}
                  onChange={(color) => update({ color })}
                />
              </label>
              <label className="range-label" htmlFor="brightness">
                亮度 <output>{signal.brightness}%</output>
              </label>
              <input
                id="brightness"
                type="range"
                min="0"
                max="100"
                value={signal.brightness}
                onChange={(e) => update({ brightness: Number(e.target.value) })}
              />
              <div className="swatches">
                {['#3B82F6', '#06B6D4', '#8B5CF6', '#F97316', '#22C55E', '#EF4444', '#FFFFFF'].map(
                  (color) => (
                    <button
                      key={color}
                      aria-label={`设为 ${color}`}
                      style={{ backgroundColor: color }}
                      onClick={() => update({ color })}
                    />
                  ),
                )}
              </div>
            </fieldset>
            {sideLocked && (
              <p className="muted">
                {theme.side.enabled ? '切换为独立配色后编辑侧灯颜色。' : '启用侧灯预览后编辑。'}
              </p>
            )}
            <label className="hold">
              完成色保持{' '}
              <input
                type="number"
                aria-label="完成色保持秒数"
                min="1"
                max="60"
                step="1"
                value={theme.completion_hold_ms / 1000}
                onChange={(e) => {
                  const n = e.target.valueAsNumber;
                  if (Number.isFinite(n))
                    setTheme({ ...theme, completion_hold_ms: Math.round(n * 1000) });
                }}
              />{' '}
              秒
            </label>
            <button
              className="preview-action"
              disabled={!ready || busy || status?.result.backend !== 'simulated'}
              onClick={preview}
            >
              在模拟核心中预览主灯
            </button>
          </div>
        </div>
      </section>
      <footer className="save-bar">
        <div role="status">
          {error || connectionError ? (
            <span className="error">{error || connectionError}</span>
          ) : (
            notice || (dirty ? '有未保存的修改' : '配色已同步')
          )}
        </div>
        <div className="actions">
          <button
            disabled={!ready || busy}
            onClick={() => {
              setTheme(defaultTheme());
              generation.current++;
            }}
          >
            默认配色
          </button>
          <button
            disabled={!dirty || busy}
            onClick={() => {
              setTheme(structuredClone(saved));
              generation.current++;
            }}
          >
            撤销
          </button>
          <button className="primary" disabled={!ready || !dirty || busy} onClick={save}>
            {busy ? '处理中…' : '保存配色'}
          </button>
        </div>
      </footer>
    </main>
  );
}
function HexField({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const [draft, setDraft] = useState(value);
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!focused) setDraft(value);
  }, [value, focused]);
  return (
    <input
      className="hex"
      aria-label="HEX 颜色"
      value={draft}
      maxLength={7}
      spellCheck={false}
      aria-invalid={!/^#[\da-f]{6}$/i.test(draft)}
      onFocus={() => setFocused(true)}
      onBlur={() => {
        setFocused(false);
        setDraft(value);
      }}
      onChange={(e) => {
        const color = e.target.value.toUpperCase();
        setDraft(color);
        if (/^#[\dA-F]{6}$/.test(color)) onChange(color);
      }}
    />
  );
}
