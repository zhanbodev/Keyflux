import { invoke, isTauri } from '@tauri-apps/api/core';
import { parseTheme, type Theme } from './theme';
export interface Status {
  result: {
    backend: string;
    state: { phase: string };
    lighting?: { color: string; brightness: number } | null;
    theme_schema_versions: number[];
  };
  desktop: { core_owned: boolean; hardware_writes: boolean; instance_id: string };
}
export interface Device {
  connected: boolean;
  writable: boolean;
  recovery_pending: boolean;
  recovery_required?: boolean;
  can_restore?: boolean;
  reconnecting?: boolean;
  last_error?: string | null;
  main?: {
    mode: 'solid' | 'effect' | 'custom';
    mode_id: number;
    brightness: number;
    color: string | null;
  };
  model_id?: string;
  firmware?: string;
  profile?: string;
  state?: number[];
  restored?: boolean;
}
export async function command<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  if (!isTauri()) throw new Error('请通过 Tauri 启动应用并连接真实 USB 键盘');
  return invoke<T>(name, args);
}
export async function loadTheme(): Promise<Theme> {
  const reply = await command<{ theme: unknown }>('get_theme');
  return parseTheme(reply.theme);
}
