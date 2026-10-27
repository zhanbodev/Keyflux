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
        theme_schema_versions: [1, 2],
      };
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
                  result: state,
                  desktop: { hardware_writes: false, core_owned: false, instance_id: 'test' },
                };
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
              case 'apply_main':
                device = {
                  ...device,
                  recovery_pending: true,
                  can_restore: true,
                  main: { mode: 'solid', mode_id: 3, ...(args.signal as object) },
                };
                return structuredClone(device);
              case 'restore_device':
                device = {
                  ...device,
                  recovery_pending: false,
                  can_restore: false,
                  main: { mode: 'effect', mode_id: 2, brightness: 60, color: null },
                };
                return { ...structuredClone(device), restored: true };
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
