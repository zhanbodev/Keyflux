import { describe, it, expect } from 'vitest';
import { defaultTheme, parseTheme, sideSignal } from './theme';
describe('Theme v2 editor boundary', () => {
  it('migrates v1 explicitly and preserves independent side edits', () => {
    const original = defaultTheme();
    const v1 = {
      schema_version: 1,
      name: original.name,
      signals: original.signals,
      completion_hold_ms: 5000,
    };
    const migrated = parseTheme(v1);
    expect(migrated.schema_version).toBe(2);
    expect(migrated.side.enabled).toBe(false);
    migrated.side.signals.thinking.color = '#FF0000';
    expect(migrated.signals.thinking.color).toBe('#06B6D4');
    expect(v1.signals.thinking.color).toBe('#06B6D4');
  });
  it('fills omitted v1 fields with the same defaults as Zig', () => {
    expect(parseTheme({})).toEqual(defaultTheme());
    const theme = parseTheme({ signals: { thinking: { color: '#112233', brightness: 20 } } });
    expect(theme.signals.thinking.color).toBe('#112233');
    expect(theme.signals.output.color).toBe('#8B5CF6');
    expect(theme.side.enabled).toBe(false);
  });
  it('normalizes partial v2 side palettes without borrowing main overrides', () => {
    const theme = parseTheme({
      schema_version: 2,
      signals: { thinking: { color: '#FF0000', brightness: 10 } },
      side: {
        enabled: true,
        mode: 'independent',
        signals: { output: { color: '#123456', brightness: 25 } },
      },
    });
    expect(theme.side.signals.thinking.color).toBe('#06B6D4');
    expect(theme.side.signals.output.color).toBe('#123456');
    expect(parseTheme({ schema_version: 2, side: null })).toEqual(defaultTheme());
  });
  it('rejects explicit v1 side fields even if null', () => {
    expect(() => parseTheme({ schema_version: 1, side: null })).toThrow();
  });
  it('does not invent an enabled side signal', () => {
    const theme = defaultTheme();
    expect(sideSignal(theme, 'thinking')).toBeNull();
    theme.side.enabled = true;
    theme.side.signals.thinking.color = '#FF0000';
    expect(sideSignal(theme, 'thinking')?.color).toBe('#06B6D4');
    theme.side.mode = 'independent';
    expect(sideSignal(theme, 'thinking')?.color).toBe('#FF0000');
  });
  it.each([
    (t: any) => (t.extra = true),
    (t: any) => (t.signals.idle = { color: '#FFFFFF', brightness: 50 }),
    (t: any) => (t.signals.thinking.color = '#abc'),
    (t: any) => (t.signals.thinking.brightness = 50.5),
    (t: any) => (t.signals.thinking.brightness = 101),
    (t: any) => (t.signals.thinking.extra = true),
    (t: any) => (t.side.mode = 'random'),
    (t: any) => (t.completion_hold_ms = 0),
    (t: any) => (t.name = '中'.repeat(22)),
  ])('rejects input outside the core contract', (mutate) => {
    const theme = defaultTheme();
    mutate(theme);
    expect(() => parseTheme(theme)).toThrow();
  });
});
