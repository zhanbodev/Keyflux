import { invoke, isTauri } from '@tauri-apps/api/core';
import { defaultTheme, parseTheme, type Theme } from './theme';
export interface Status {
  result: { backend: string; state: { phase: string }; theme_schema_versions: number[] };
  desktop: { core_owned: boolean; hardware_writes: boolean; instance_id: string };
}
export const fixture = !isTauri() && new URLSearchParams(location.search).get('fixture') === '1';
let demoTheme = defaultTheme();
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
    case 'preview_main':
      return { ok: true } as T;
    default:
      throw new Error('浏览器样例不支持本地文件对话框');
  }
}
export async function loadTheme(): Promise<Theme> {
  const reply = await command<{ theme: unknown }>('get_theme');
  return parseTheme(reply.theme);
}
