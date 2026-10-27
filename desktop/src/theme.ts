export const phases = [
  'working',
  'thinking',
  'output',
  'tool',
  'attention',
  'complete',
  'error',
  'checking',
  'verified',
  'check_failed',
] as const;
export type Phase = (typeof phases)[number];
export type Signal = { color: string; brightness: number };
export const effects = ['solid', 'marquee', 'orbit', 'blink'] as const;
export type Action = { effect: (typeof effects)[number]; speed: number };
export const effectLabels = { solid: '常亮', marquee: '跑马灯', orbit: '绕圈', blink: '星点闪烁' };
export type Palette = Record<Phase, Signal>;
export type Theme = {
  schema_version: 3;
  actions: Record<Phase, Action>;
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
  checking: '验证中',
  verified: '验证通过',
  check_failed: '验证失败',
  idle: '空闲',
  unavailable: '状态不可用',
};
const colors = [
  '#3B82F6',
  '#06B6D4',
  '#8B5CF6',
  '#3B82F6',
  '#F97316',
  '#22C55E',
  '#EF4444',
  '#6366F1',
  '#22C55E',
  '#F43F5E',
];
export function defaultTheme(): Theme {
  const signals = Object.fromEntries(
    phases.map((p, i) => [p, { color: colors[i], brightness: 50 }]),
  ) as Palette;
  return {
    schema_version: 3,
    actions: Object.fromEntries(phases.map((p) => [p, { effect: 'solid', speed: 3 }])) as Record<
      Phase,
      Action
    >,
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
function allowed(value: Record<string, unknown>, fields: readonly string[]): boolean {
  return Object.keys(value).every((key) => fields.includes(key));
}
function palette(value: unknown, defaults: Palette): Palette {
  if (value === undefined) return structuredClone(defaults);
  if (!record(value) || !allowed(value, phases)) throw new Error('配色状态字段无效');
  const result = structuredClone(defaults);
  for (const phase of phases) {
    if (!Object.hasOwn(value, phase)) continue;
    const signal = value[phase];
    if (
      !record(signal) ||
      !keys(signal, ['color', 'brightness']) ||
      typeof signal.color !== 'string' ||
      !/^#[\da-f]{6}$/i.test(signal.color) ||
      typeof signal.brightness !== 'number' ||
      !Number.isInteger(signal.brightness) ||
      signal.brightness < 0 ||
      signal.brightness > 100
    )
      throw new Error('配色颜色或亮度无效');
    result[phase] = { color: signal.color, brightness: signal.brightness };
  }
  return result;
}
export function parseTheme(value: unknown): Theme {
  if (
    !record(value) ||
    !allowed(value, ['schema_version', 'name', 'completion_hold_ms', 'signals', 'side', 'actions'])
  )
    throw new Error('不支持的配色格式或字段');
  const version = value.schema_version === undefined ? 1 : value.schema_version;
  if (
    ![1, 2, 3].includes(version as number) ||
    ((version as number) < 3 && Object.hasOwn(value, 'actions')) ||
    (version === 1 && Object.hasOwn(value, 'side'))
  )
    throw new Error('不支持的配色格式或字段');
  const defaults = defaultTheme();
  const name = value.name === undefined ? defaults.name : value.name;
  const hold =
    value.completion_hold_ms === undefined ? defaults.completion_hold_ms : value.completion_hold_ms;
  if (
    typeof name !== 'string' ||
    new TextEncoder().encode(name).length < 1 ||
    new TextEncoder().encode(name).length > 64 ||
    typeof hold !== 'number' ||
    !Number.isInteger(hold) ||
    hold < 1000 ||
    hold > 60000
  )
    throw new Error('配色名称、保持时间或颜色无效');
  if ((version as number) < 3) {
    for (const candidate of [value.signals, record(value.side) ? value.side.signals : null])
      if (
        record(candidate) &&
        ['checking', 'verified', 'check_failed'].some((p) => Object.hasOwn(candidate, p))
      )
        throw new Error('验证配色需要 Theme v3');
  }
  const signals = palette(value.signals, defaults.signals);
  const side = value.side;
  let normalizedSide = structuredClone(defaults.side);
  if (version === 1) normalizedSide.signals = structuredClone(signals);
  else if (side !== undefined && side !== null) {
    if (!record(side) || !allowed(side, ['enabled', 'mode', 'signals']))
      throw new Error('侧灯配色无效');
    const enabled = side.enabled === undefined ? false : side.enabled;
    const mode = side.mode === undefined ? 'follow_main' : side.mode;
    if (typeof enabled !== 'boolean' || (mode !== 'follow_main' && mode !== 'independent'))
      throw new Error('侧灯配色无效');
    normalizedSide = { enabled, mode, signals: palette(side.signals, defaults.signals) };
  }
  const actions = structuredClone(defaults.actions);
  if (value.actions !== undefined && value.actions !== null) {
    if (!record(value.actions) || !allowed(value.actions, phases))
      throw new Error('灯光动作字段无效');
    for (const phase of phases) {
      const action = value.actions[phase];
      if (action === undefined) continue;
      if (!record(action) || !allowed(action, ['effect', 'speed'])) throw new Error('灯光动作无效');
      const effect = action.effect === undefined ? 'solid' : action.effect;
      const speed = action.speed === undefined ? 3 : action.speed;
      if (
        !effects.includes(effect as Action['effect']) ||
        typeof speed !== 'number' ||
        !Number.isInteger(speed) ||
        speed < 1 ||
        speed > 5
      )
        throw new Error('灯光动作或速度无效');
      actions[phase] = { effect: effect as Action['effect'], speed };
    }
  }
  return {
    schema_version: 3,
    name,
    completion_hold_ms: hold,
    signals,
    side: normalizedSide,
    actions,
  };
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
