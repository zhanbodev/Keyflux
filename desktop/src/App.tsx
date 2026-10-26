import { useEffect, useState } from 'react';
import { command, fixture, loadTheme, type Device, type Status } from './bridge';
import { KeyboardPreview, layouts } from './KeyboardPreview';
import { ColorPicker } from './ColorPicker';
import { Select } from './Select';
import { MoreMenu } from './MoreMenu';
import { Brightness } from './Brightness';
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
const disconnected: Device = { connected: false, writable: false, recovery_pending: false };
const errorText = (error: unknown) => {
  const code = String(error).replace(/^Error: /, '');
  return (
    (
      {
        Kick75NotFound: '未找到 Kick75，请检查 USB 连接',
        DeviceNotFound: '未找到 Kick75，请检查 USB 连接',
        HidOpenFailed: '键盘被其他灯控程序占用',
        NotConnected: '请先连接键盘',
        RecoveryRequired: '有未完成的写入，请先恢复灯效',
        ConcurrentDeviceChange: '检测到其他灯控修改，请先恢复灯效',
        DeviceChanged: '设备已改变，请重新连接',
        UnverifiedDevice: '当前系统、固件或档位尚未通过灯控验证',
        SimulationNotAllowed: '当前为模拟实例，请使用普通启动命令',
        ReadbackMismatch: '灯光回读不一致，请恢复灯效',
      } as Record<string, string>
    )[code] ?? code
  );
};
export function App() {
  const [theme, setTheme] = useState<Theme>(defaultTheme),
    [saved, setSaved] = useState<Theme>(defaultTheme);
  const [status, setStatus] = useState<Status | null>(null),
    [device, setDevice] = useState<Device>(disconnected);
  const [ready, setReady] = useState(false),
    [busy, setBusy] = useState(false);
  const [error, setError] = useState(''),
    [connectionError, setConnectionError] = useState(''),
    [notice, setNotice] = useState('');
  const [model, setModel] = useState(layouts[0].id),
    [phase, setPhase] = useState<Phase>('working');
  const [follow, setFollow] = useState(false),
    [zone, setZone] = useState<'main' | 'side'>('main');
  const dirty = JSON.stringify(theme) !== JSON.stringify(saved);
  useEffect(() => {
    let disposed = false,
      polls = 0;
    let timer: ReturnType<typeof setTimeout>;
    const check = (next: Status) => {
      if (!next.result.theme_schema_versions?.includes(2)) throw new Error('核心不支持 Theme v2');
      if (!fixture && next.result.backend === 'simulated') throw new Error('SimulationNotAllowed');
    };
    const refresh = async () => {
      if (document.visibilityState !== 'hidden')
        try {
          const next = await command<Status>('get_status');
          if (disposed) return;
          check(next);
          setStatus(next);
          setConnectionError('');
          if (++polls % 3 === 0) {
            const nextDevice = await command<Device>('get_device');
            if (!disposed) setDevice(nextDevice);
          }
        } catch (e) {
          if (!disposed) {
            setStatus(null);
            setConnectionError(errorText(e));
          }
        }
      if (!disposed) timer = setTimeout(refresh, 1500);
    };
    const init = async () => {
      try {
        const [next, loaded, connected] = await Promise.all([
          command<Status>('get_status'),
          loadTheme(),
          command<Device>('get_device'),
        ]);
        if (disposed) return;
        check(next);
        setStatus(next);
        setTheme(loaded);
        setSaved(structuredClone(loaded));
        setDevice(connected);
        setReady(true);
        setConnectionError('');
        if (!fixture && !connected.connected) {
          try {
            const usb = await command<Device>('connect_device');
            if (disposed) return;
            setDevice(usb);
            if (usb.model_id) setModel(usb.model_id);
          } catch {
            // No hardware is a normal startup state. The connection button
            // retries explicitly; it never substitutes a simulated keyboard.
          }
        }
        timer = setTimeout(refresh, 1500);
      } catch (e) {
        if (!disposed) {
          setConnectionError(errorText(e));
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
  useEffect(() => {
    const guard = (event: BeforeUnloadEvent) => {
      if (dirty) event.preventDefault();
    };
    window.addEventListener('beforeunload', guard);
    return () => window.removeEventListener('beforeunload', guard);
  }, [dirty]);
  const live = status?.result.state.phase;
  const displayed = follow ? (phases.includes(live as Phase) ? (live as Phase) : null) : phase;
  const editPhase = displayed ?? phase;
  const signal =
    zone === 'main' || theme.side.mode === 'follow_main'
      ? theme.signals[editPhase]
      : theme.side.signals[editPhase];
  const beginEdit = () => {
    if (follow) {
      setPhase(editPhase);
      setFollow(false);
    }
  };
  const update = (value: Partial<Signal>) => {
    beginEdit();
    setTheme((previous) => {
      const next = structuredClone(previous);
      Object.assign(
        zone === 'main' ? next.signals[editPhase] : next.side.signals[editPhase],
        value,
      );
      return next;
    });
  };
  const run = async (task: () => Promise<void>) => {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      await task();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  const connect = () =>
    void run(async () => {
      if (device.connected) {
        await command('disconnect_device');
        setDevice(disconnected);
        setNotice('已断开连接');
      } else {
        const next = await command<Device>('connect_device');
        setDevice(next);
        if (next.model_id) setModel(next.model_id);
        setNotice(next.writable ? 'USB 已连接，可应用主灯颜色' : 'USB 已连接，当前设备仅支持回读');
      }
    });
  const locked = zone === 'side' && (!theme.side.enabled || theme.side.mode === 'follow_main');
  const canApply =
    device.connected && device.writable && device.model_id === model && zone === 'main';
  return (
    <main className="app-shell">
      <header className="toolbar">
        <Select
          label="键盘型号"
          value={model}
          onChange={setModel}
          options={layouts.map((l) => ({
            value: l.id,
            label: l.name + (l.preview_only ? ' · 布局样例' : ''),
          }))}
        />
        <div className="toolbar-right">
          <label className="toggle">
            <input type="checkbox" checked={follow} onChange={(e) => setFollow(e.target.checked)} />
            跟随状态
          </label>
          <span
            className={`connection ${device.connected ? 'online' : ''}`}
            title={device.firmware ? `固件 ${device.firmware} · ${device.profile} 档` : undefined}
          >
            <i />
            {fixture
              ? '界面测试'
              : device.connected
                ? device.writable
                  ? 'USB 已连接'
                  : 'USB 只读'
                : '未连接'}
          </span>
          <button className="connect-button" disabled={busy || !ready} onClick={connect}>
            {device.connected ? '断开' : '连接键盘'}
          </button>
          <MoreMenu
            disabled={!ready || busy}
            actions={[
              {
                id: 'import-theme',
                label: '导入配色',
                onSelect: () =>
                  void run(async () => {
                    const imported = await command<unknown>('import_theme');
                    if (imported !== null) {
                      setTheme(parseTheme(imported));
                      setNotice('已导入，保存后生效');
                    }
                  }),
              },
              {
                id: 'export-theme',
                label: '导出配色',
                onSelect: () =>
                  void run(async () => {
                    if (await command<boolean>('export_theme', { theme: parseTheme(theme) }))
                      setNotice('配色已导出');
                  }),
              },
            ]}
          />
        </div>
      </header>
      <section className="keyboard-stage" aria-label="键盘预览区">
        <KeyboardPreview
          model={model}
          main={displayed ? theme.signals[displayed] : null}
          strip={displayed ? sideSignal(theme, displayed) : null}
        />
      </section>
      <section className="console">
        <nav className="zone-nav" aria-label="灯区">
          <button className={zone === 'main' ? 'active' : ''} onClick={() => setZone('main')}>
            <svg width="19" height="19" viewBox="0 0 24 24" aria-hidden="true">
              <rect x="2" y="5" width="20" height="14" rx="2" />
              <path d="M6 9h1m4 0h1m4 0h1M6 13h1m4 0h1m4 0h1M8 16h8" />
            </svg>
            主键区
          </button>
          <button className={zone === 'side' ? 'active' : ''} onClick={() => setZone('side')}>
            <svg width="19" height="19" viewBox="0 0 24 24" aria-hidden="true">
              <rect x="3" y="8" width="18" height="8" rx="2" />
              <path d="M7 11v2m5-2v2m5-2v2" />
            </svg>
            条形灯
          </button>
        </nav>
        <div className="states" aria-label="状态配色">
          {phases.map((p) => {
            const swatch =
              zone === 'main' || theme.side.mode === 'follow_main'
                ? theme.signals[p]
                : theme.side.signals[p];
            return (
              <button
                key={p}
                className={editPhase === p ? 'selected' : ''}
                aria-pressed={editPhase === p}
                onClick={() => {
                  setFollow(false);
                  setPhase(p);
                }}
              >
                <i style={{ backgroundColor: swatch.color }} />
                <span>{labels[p]}</span>
                {follow && p === live && <span className="live-dot" aria-label="当前状态" />}
              </button>
            );
          })}
        </div>
        <div className="color-panel">
          <div className="panel-heading">
            <h2>{labels[editPhase]}</h2>
            {zone === 'side' ? (
              <div className="strip-controls">
                <label className="toggle">
                  <input
                    type="checkbox"
                    checked={theme.side.enabled}
                    onChange={(e) =>
                      setTheme({ ...theme, side: { ...theme.side, enabled: e.target.checked } })
                    }
                  />
                  启用条形灯
                </label>
                <Select
                  label="条形灯配色模式"
                  value={theme.side.mode}
                  onChange={(mode) =>
                    setTheme({
                      ...theme,
                      side: { ...theme.side, mode: mode as Theme['side']['mode'] },
                    })
                  }
                  options={[
                    { value: 'follow_main', label: '跟随主键区' },
                    { value: 'independent', label: '独立配色' },
                  ]}
                />
              </div>
            ) : (
              <span className="phase-caption">
                {follow
                  ? displayed
                    ? '当前状态'
                    : live === 'idle'
                      ? '当前空闲'
                      : '状态不可用'
                  : '配色预览'}
              </span>
            )}
          </div>
          <ColorPicker
            value={signal.color}
            disabled={!ready || busy || locked}
            onBegin={beginEdit}
            onChange={(color) => update({ color })}
          />
          <div className="channel-row">
            <Brightness
              value={signal.brightness}
              disabled={!ready || busy || locked}
              onBegin={beginEdit}
              onChange={(brightness) => update({ brightness })}
            />
            {zone === 'side' && (
              <span className="strip-hint">
                {locked
                  ? theme.side.enabled
                    ? '跟随主键区颜色'
                    : '启用后预览条形灯'
                  : '条形灯暂不写入设备'}
              </span>
            )}
          </div>
        </div>
      </section>
      <footer className="save-bar">
        <div className="feedback" role="status">
          {error || connectionError ? (
            <span className="error">{error || connectionError}</span>
          ) : (
            notice ||
            (dirty
              ? '未保存'
              : device.connected
                ? device.firmware
                  ? `Kick75 IO · ${device.firmware}`
                  : '已连接'
                : '选择配色，连接键盘后应用')
          )}
        </div>
        <label className="hold">
          完成保持
          <input
            type="number"
            aria-label="完成色保持秒数"
            min="1"
            max="60"
            value={theme.completion_hold_ms / 1000}
            onChange={(e) => {
              if (Number.isFinite(e.target.valueAsNumber))
                setTheme({
                  ...theme,
                  completion_hold_ms: Math.round(e.target.valueAsNumber * 1000),
                });
            }}
          />
          秒
        </label>
        <div className="actions">
          <button disabled={!ready || busy} onClick={() => setTheme(defaultTheme())}>
            默认
          </button>
          <button
            disabled={!dirty || busy}
            onClick={() => {
              setTheme(structuredClone(saved));
              setError('');
            }}
          >
            撤销
          </button>
          <button
            disabled={!device.connected || !device.writable || busy}
            onClick={() =>
              void run(async () => {
                const restored = await command<Device>('restore_device');
                setDevice(restored);
                setNotice(
                  restored.restored === false ? '没有待恢复的灯效' : '原灯效已恢复并回读确认',
                );
              })
            }
          >
            恢复灯效
          </button>
          <button
            disabled={!canApply || busy}
            onClick={() =>
              void run(async () => {
                setDevice(
                  await command<Device>('apply_main', { signal: theme.signals[editPhase], model }),
                );
                setNotice('主灯已应用，回读确认');
              })
            }
          >
            应用到键盘
          </button>
          <button
            className="primary"
            disabled={!ready || !dirty || busy}
            onClick={() =>
              void run(async () => {
                const validated = parseTheme(theme);
                await command('save_theme', { theme: validated });
                setSaved(structuredClone(validated));
                setNotice('配色已保存');
              })
            }
          >
            保存
          </button>
        </div>
      </footer>
    </main>
  );
}
