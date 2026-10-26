export const phases = [
  'working',
  'thinking',
  'output',
  'tool',
  'attention',
  'complete',
  'error',
] as const;
export type Phase = (typeof phases)[number];
export type Signal = { color: string; brightness: number };
export type Palette = Record<Phase, Signal>;
export type Theme = {
  schema_version: 2;
  name: string;
  completion_hold_ms: number;
  signals: Palette;
  side: { enabled: boolean; mode: 'follow_main' | 'independent'; signals: Palette };
};
export const labels: Record<Phase | 'idle' | 'unavailable', string> = {
  working: '工作中',
  thinking: 'Thinking',
  output: '输出中',
  tool: '工具执行',
  attention: '待处理',
  complete: '本轮结束',
  error: '错误',
  idle: '空闲',
  unavailable: '状态不可用',
};
const colors = ['#3B82F6', '#06B6D4', '#8B5CF6', '#3B82F6', '#F97316', '#22C55E', '#EF4444'];
export function defaultTheme(): Theme {
  const signals = Object.fromEntries(
    phases.map((p, i) => [p, { color: colors[i], brightness: 50 }]),
  ) as Palette;
  return {
    schema_version: 2,
    name: 'Keyflux',
    completion_hold_ms: 5000,
    signals,
    side: { enabled: false, mode: 'follow_main', signals: structuredClone(signals) },
  };
}
function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
function keys(value: Record<string, unknown>, expected: string[]) {
  return (
    Object.keys(value).length === expected.length && expected.every((k) => Object.hasOwn(value, k))
  );
}
function palette(value: unknown): value is Palette {
  return (
    record(value) &&
    keys(value, [...phases]) &&
    phases.every((p) => {
      const s = value[p];
      return (
        record(s) &&
        keys(s, ['color', 'brightness']) &&
        typeof s.color === 'string' &&
        /^#[\da-f]{6}$/i.test(s.color) &&
        typeof s.brightness === 'number' &&
        Number.isInteger(s.brightness) &&
        s.brightness >= 0 &&
        s.brightness <= 100
      );
    })
  );
}
export function parseTheme(value: unknown): Theme {
  if (
    !record(value) ||
    ![1, 2].includes(value.schema_version as number) ||
    !keys(value, [
      'schema_version',
      'name',
      'completion_hold_ms',
      'signals',
      ...(value.schema_version === 2 ? ['side'] : []),
    ])
  )
    throw new Error('不支持的配色格式或字段');
  if (
    typeof value.name !== 'string' ||
    new TextEncoder().encode(value.name).length < 1 ||
    new TextEncoder().encode(value.name).length > 64 ||
    !Number.isInteger(value.completion_hold_ms) ||
    (value.completion_hold_ms as number) < 1000 ||
    (value.completion_hold_ms as number) > 60000 ||
    !palette(value.signals)
  )
    throw new Error('配色名称、保持时间或颜色无效');
  const side = value.side;
  if (
    value.schema_version === 2 &&
    (!record(side) ||
      !keys(side, ['enabled', 'mode', 'signals']) ||
      typeof side.enabled !== 'boolean' ||
      !['follow_main', 'independent'].includes(side.mode as string) ||
      !palette(side.signals))
  )
    throw new Error('侧灯配色无效');
  return structuredClone({
    ...value,
    schema_version: 2,
    side:
      value.schema_version === 1
        ? { enabled: false, mode: 'follow_main', signals: structuredClone(value.signals) }
        : side,
  }) as Theme;
}
export function sideSignal(theme: Theme, phase: Phase): Signal | null {
  return !theme.side.enabled
    ? null
    : theme.side.mode === 'follow_main'
      ? theme.signals[phase]
      : theme.side.signals[phase];
}
export function tint(signal: Signal | null): string {
  if (!signal) return 'transparent';
  return `${signal.color}${Math.round((signal.brightness / 100) * 150)
    .toString(16)
    .padStart(2, '0')}`;
}
