import { spawn, execFileSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
execFileSync(process.execPath, ['scripts/prepare-core.mjs'], { cwd: desktop, stdio: 'inherit' });
execFileSync(process.execPath, ['scripts/reference-assets.mjs'], {
  cwd: desktop,
  stdio: 'inherit',
});
const cli = resolve(desktop, 'node_modules/@tauri-apps/cli/tauri.js');
const child = spawn(process.execPath, [cli, ...process.argv.slice(2)], {
  cwd: desktop,
  stdio: 'inherit',
  env: {
    ...process.env,
    KEYFLUX_CORE: resolve(
      desktop,
      '.build/core/bin/keyflux' + (process.platform === 'win32' ? '.exe' : ''),
    ),
  },
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('exit', (code) => process.exit(code ?? 1));
