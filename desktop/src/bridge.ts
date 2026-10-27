import { invoke, isTauri } from '@tauri-apps/api/core';
import { parseTheme, type Theme, type Action } from './theme';
export interface Task {
  label: string | null;
  provider: string;
  session_id: string;
  turn_id: string;
  phase: string;
  ended: boolean;
  cancelled: boolean;
  acknowledged: boolean;
  updated_ns: number;
  active_tasks: number;
  pending_approvals: number;
  pending_inputs: number;
  pending_other: number;
  check_type: 'test' | 'build' | null;
}
export interface Status {
  tasks?: Task[];
  result: {
    backend: string;
    state: { phase: string };
    action?: Action;
    lighting?: { color: string; brightness: number } | null;
    theme_schema_versions: number[];
  };
  desktop: {
    core_owned: boolean;
    hardware_writes: boolean;
    instance_id: string;
    source?: { available: boolean; code: string | null; streaming_phases: boolean };
  };
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
