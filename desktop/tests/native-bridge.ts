import type { Page } from '@playwright/test';
import { defaultTheme } from '../src/theme';

// Test-only Tauri boundary injection. No mock transport is shipped in src/.
export async function installBridge(page: Page, failConnect = false) {
  await page.addInitScript(
    ({ theme, failConnect }) => {
      let currentTheme = theme;
      let device: Record<string, unknown> = {
        connected: false,
        writable: false,
        recovery_pending: false,
      };
      const state = {
        backend: 'read-only',
        state: { phase: 'thinking' },
        theme_schema_versions: [1, 2, 3],
      };
      const tasks = [
        {
          provider: 'codex.desktop.local',
          session_id: '019a0000-0000-7000-8000-000000000001',
          turn_id: 't1',
          phase: 'attention',
          ended: false,
          cancelled: false,
          acknowledged: false,
          updated_ns: 3,
          active_tasks: 1,
          pending_approvals: 0,
          pending_inputs: 1,
          pending_other: 0,
          check_type: null,
          label: null,
        },
        {
          provider: 'keyflux.check',
          session_id: 'check-build',
          turn_id: 'r1',
          phase: 'check_failed',
          ended: true,
          cancelled: false,
          acknowledged: false,
          updated_ns: 2,
          active_tasks: 0,
          pending_approvals: 0,
          pending_inputs: 0,
          pending_other: 0,
          check_type: 'build',
          label: 'keyflux',
        },
      ];
      const calls: string[] = [];
      Object.assign(window, {
        isTauri: true,
        __testBridge: {
          calls,
          unplug: () => {
            device = {
              connected: false,
              writable: false,
              recovery_pending: false,
              last_error: 'DeviceDisconnected',
            };
          },
        },
        __TAURI_INTERNALS__: {
          invoke: async (name: string, args: Record<string, unknown> = {}) => {
            calls.push(name);
            switch (name) {
              case 'get_status':
                return {
                  result: { ...state, lighting: currentTheme.signals.thinking },
                  tasks: structuredClone(tasks),
                  desktop: { hardware_writes: false, core_owned: false, instance_id: 'test' },
                };
              case 'open_task':
                return null;
              case 'acknowledge_task': {
                const task = tasks.find(
                  (t) =>
                    t.provider === args.provider &&
                    t.session_id === args.sessionId &&
                    t.turn_id === args.turnId,
                );
                if (task) task.acknowledged = true;
                return { ok: true };
              }
              case 'get_theme':
                return { theme: structuredClone(currentTheme) };
              case 'save_theme':
                currentTheme = structuredClone(args.theme as typeof theme);
                return { ok: true };
              case 'get_device':
                return structuredClone(device);
              case 'connect_device':
                if (failConnect) throw new Error('DeviceNotFound');
                device = {
                  connected: true,
                  writable: true,
                  recovery_pending: false,
                  model_id: 'nuphy-kick75-io',
                  firmware: 'test',
                  profile: 'Mac',
                  main: { mode: 'effect', mode_id: 2, brightness: 60, color: null },
                };
                return structuredClone(device);
              case 'disconnect_device':
                device = { connected: false, writable: false, recovery_pending: false };
                return structuredClone(device);
              default:
                throw new Error('Test does not implement file dialogs');
            }
          },
        },
      });
    },
    { theme: defaultTheme(), failConnect },
  );
}
