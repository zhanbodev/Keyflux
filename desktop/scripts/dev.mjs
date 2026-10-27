import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const desktop = resolve(root, 'desktop');
const args = process.argv.slice(2);
const help = `Usage: ./scripts/dev-macos.sh [--demo] [--no-ui] [--no-build] [--check] [--state-dir PATH]
Tauri 2 + React/TypeScript; requires Node 24+, Rust stable, Zig 0.17.0 and platform SDK.
--demo cycles synthetic agent events. No real keyboard writes or Codex connection.
--check builds and tests without opening a window. --no-build skips Zig rebuilding.
Normal startup uses the real read-only core; connect USB from the App.
--demo is available only with --no-ui for synthetic CLI debugging.
State is isolated from installed apps. Close settings to keep tray/core running;
quit the tray app or press Ctrl+C to end this supervised development session.`;
let demo = false,
  noUI = false,
  noBuild = false,
  check = false;
let directory = resolve(
  tmpdir(),
  `keyflux-tauri-${createHash('sha256').update(root).digest('hex').slice(0, 8)}`,
);
for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--help':
    case '-h':
      console.log(help);
      process.exit(0);
    case '--demo':
      demo = true;
      break;
    case '--no-ui':
      noUI = true;
      break;
    case '--no-build':
      noBuild = true;
      break;
    case '--check':
      check = true;
      break;
    case '--state-dir':
      if (!args[++i]) throw new Error('Missing --state-dir path');
      directory = resolve(args[i]);
      break;
    default:
      throw new Error(`Unknown option ${args[i]}\n${help}`);
  }
}
if (demo && !noUI && !check)
  throw new Error(
    'Use --demo with --no-ui only. Start the App without --demo to connect a real keyboard.',
  );
function run(command, argv, options = {}) {
  return execFileSync(command, argv, { cwd: root, stdio: 'inherit', ...options });
}
if (!noBuild) run(process.execPath, [resolve(desktop, 'scripts/prepare-core.mjs')]);
const binary = resolve(
  desktop,
  `.build/core/bin/keyflux${process.platform === 'win32' ? '.exe' : ''}`,
);
if (check) {
  // Windows npm.cmd needs cmd.exe; these are fixed build script names, not
  // user-supplied shell commands. Unix invokes npm directly.
  for (const script of ['test', 'frontend:build'])
    run(
      process.platform === 'win32' ? 'cmd.exe' : 'npm',
      process.platform === 'win32' ? ['/d', '/s', '/c', `npm run ${script}`] : ['run', script],
      { cwd: desktop },
    );
  run('cargo', ['test', '--locked', '--manifest-path', resolve(desktop, 'src-tauri/Cargo.toml')], {
    env: { ...process.env, KEYFLUX_TEST_CORE: binary },
  });
  run('zig', ['build', 'test', '-j2']);
  const python = process.platform === 'win32' ? 'python' : 'python3';
  for (const test of [
    'scripts/validate-keyboard-previews.py',
    'tests/preview_layouts.py',
    'tests/codex_phase_probe.py',
  ])
    run(python, [test]);
  run(python, ['tests/integration.py', binary]);
  run(python, ['tests/workflow.py', binary]);
  console.log('Desktop and Zig checks passed.');
  process.exit(0);
}
mkdirSync(directory, { recursive: true });
directory = realpathSync.native(directory);
function cli(op, input) {
  return execFileSync(binary, [op, '--state-dir', directory], {
    input: input === undefined ? undefined : JSON.stringify(input),
    stdio: ['pipe', 'pipe', 'pipe'],
    timeout: 5000,
  });
}
try {
  cli('status');
  throw new Error('InstanceAlreadyRunning');
} catch (e) {
  if (e.message === 'InstanceAlreadyRunning')
    throw new Error(
      `A core already owns ${directory}. Stop that instance or select another --state-dir.`,
    );
}
if (!noUI) run(process.execPath, [resolve(desktop, 'scripts/reference-assets.mjs')]);
const core = spawn(binary, ['serve', ...(demo ? ['--simulate'] : []), '--state-dir', directory], {
  stdio: ['ignore', 'pipe', 'inherit'],
});
let ui,
  timer,
  stopping = false,
  owned = false,
  ready = false,
  startup = '';
core.stdout.on('data', (chunk) => {
  process.stdout.write(chunk);
  startup = (startup + chunk.toString()).slice(-4096);
  for (const line of startup.split('\n').slice(0, -1)) {
    try {
      if (JSON.parse(line).ready === true) ready = true;
    } catch {}
  }
});
async function cleanup(code = 0) {
  if (stopping) return;
  stopping = true;
  clearTimeout(timer);
  if (owned) {
    try {
      cli('stop');
    } catch {}
  }
  ui?.kill('SIGTERM');
  // The simulated core is owned by this launcher; wait for restoration first.
  for (let i = 0; i < 30 && core.exitCode === null; i++)
    await new Promise((r) => setTimeout(r, 100));
  if (core.exitCode === null) core.kill();
  process.exit(code);
}
process.on('SIGINT', () => void cleanup(130));
process.on('SIGTERM', () => void cleanup(143));
core.on('error', (e) => {
  console.error(e.message);
  void cleanup(1);
});
core.on('exit', (code) => {
  if (!stopping) void cleanup(code ?? 1);
});
for (let i = 0; i < 50; i++) {
  try {
    if (!ready || core.exitCode !== null) throw new Error('Not ready');
    const result = JSON.parse(cli('status'));
    if (result.result.backend !== (demo ? 'simulated' : 'read-only'))
      throw new Error('Unexpected core mode');
    owned = true;
    break;
  } catch {}
  await new Promise((r) => setTimeout(r, 100));
}
if (!owned) {
  console.error('Core startup failed.');
  await cleanup(1);
}
console.log(
  `Isolated state: ${directory}\n${demo ? 'Synthetic CLI events only.' : 'Read-only core. Connect a USB keyboard from the App.'} Ctrl+C to stop.`,
);
if (demo) {
  const kinds = [
    'turn_started',
    'thinking',
    'output',
    'tool_started',
    'attention',
    'attention_resolved',
    'tool_finished',
    'turn_completed',
  ];
  let index = 0,
    turn = 1;
  const emit = () => {
    if (stopping) return;
    const kind = kinds[index];
    const event = {
      schema_version: 1,
      provider: 'keyflux.dev',
      session_id: `demo-${process.pid}`,
      turn_id: `turn-${turn}`,
      event_id: `${turn}-${index}`,
      timestamp_ns: JSON.rawJSON((BigInt(Date.now()) * 1000000n).toString()),
      kind,
      ...(['tool_started', 'attention', 'attention_resolved', 'tool_finished'].includes(kind)
        ? { request_id: `call-${turn}` }
        : {}),
    };
    try {
      cli('emit', event);
    } catch (e) {
      console.error('Demo event rejected:', e.message);
      void cleanup(1);
      return;
    }
    index = (index + 1) % kinds.length;
    if (!index) turn++;
    timer = setTimeout(emit, index ? 2000 : 6500);
  };
  emit();
}
if (!noUI) {
  const uiEnvironment = { ...process.env, KEYFLUX_CORE: binary, KEYFLUX_STATE_DIR: directory };
  delete uiEnvironment.KEYFLUX_SIMULATE;
  ui = spawn(process.execPath, [resolve(desktop, 'node_modules/@tauri-apps/cli/tauri.js'), 'dev'], {
    cwd: desktop,
    stdio: 'inherit',
    env: uiEnvironment,
  });
  ui.on('error', (e) => {
    console.error(e.message);
    void cleanup(1);
  });
  ui.on('exit', (code) => void cleanup(code ?? 1));
}
