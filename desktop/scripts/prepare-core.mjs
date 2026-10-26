import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const triple =
  process.env.KEYFLUX_TARGET ??
  execFileSync('rustc', ['-vV'], { encoding: 'utf8' }).match(/^host: (.+)$/m)?.[1];
if (!triple) throw new Error('Rust host target unavailable');
const prefix = resolve(root, 'desktop/.build/core');
const args = ['build', '-Doptimize=ReleaseSafe', '--prefix', prefix, '-j2'];
if (process.env.KEYFLUX_ZIG_TARGET) args.push(`-Dtarget=${process.env.KEYFLUX_ZIG_TARGET}`);
execFileSync('zig', args, { cwd: root, stdio: 'inherit' });
mkdirSync(resolve(root, 'desktop/src-tauri/binaries'), { recursive: true });
copyFileSync(
  resolve(prefix, `bin/keyflux${triple.includes('windows') ? '.exe' : ''}`),
  resolve(
    root,
    `desktop/src-tauri/binaries/keyflux-${triple}${triple.includes('windows') ? '.exe' : ''}`,
  ),
);
console.log(`Bundled Zig core: ${triple}`);
