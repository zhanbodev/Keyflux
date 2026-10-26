import { invoke, isTauri } from '@tauri-apps/api/core';
import { defaultTheme, parseTheme, type Theme } from './theme';
export interface Status {
  result: { backend: string; state: { phase: string }; theme_schema_versions: number[] };
  desktop: { core_owned: boolean; hardware_writes: boolean; instance_id: string };
}
export interface Device {
  connected: boolean;
  writable: boolean;
  recovery_pending: boolean;
  model_id?: string;
  firmware?: string;
  profile?: string;
  state?: number[];
  restored?: boolean;
}
export const fixture = !isTauri() && new URLSearchParams(location.search).get('fixture') === '1';
let demoTheme = defaultTheme();
let demoDevice: Device = { connected: false, writable: false, recovery_pending: false };
const demoStatus: Status = {
  result: { backend: 'simulated', state: { phase: 'thinking' }, theme_schema_versions: [1, 2] },
  desktop: { core_owned: false, hardware_writes: false, instance_id: 'browser-fixture' },
};
export async function command<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  if (isTauri()) return invoke<T>(name, args);
  if (!fixture) throw new Error('请通过 Tauri 启动应用。浏览器仅支持显式 fixture 预览。');
  switch (name) {
    case 'get_status':
      return structuredClone(demoStatus) as T;
    case 'get_theme':
      return { ok: true, theme: structuredClone(demoTheme) } as T;
    case 'save_theme':
      demoTheme = parseTheme(args?.theme);
      return { ok: true } as T;
    case 'get_device':
      return structuredClone(demoDevice) as T;
    case 'connect_device':
      demoDevice = {
        connected: true,
        writable: true,
        recovery_pending: false,
        model_id: 'nuphy-kick75-io',
        firmware: 'fixture',
        profile: 'Mac',
      };
      return structuredClone(demoDevice) as T;
    case 'apply_main':
      demoDevice.recovery_pending = true;
      return structuredClone(demoDevice) as T;
    case 'restore_device':
      demoDevice.recovery_pending = false;
      return { ...structuredClone(demoDevice), restored: true } as T;
    case 'disconnect_device':
      demoDevice = { connected: false, writable: false, recovery_pending: false };
      return structuredClone(demoDevice) as T;
    default:
      throw new Error('浏览器样例不支持本地文件对话框');
  }
}
export async function loadTheme(): Promise<Theme> {
  const reply = await command<{ theme: unknown }>('get_theme');
  return parseTheme(reply.theme);
}
