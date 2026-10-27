# P0 workflows and native lighting actions

The desktop app follows real local Codex Desktop lifecycle records. Its **Tasks**
view lists each tracked turn, prioritizes pending input/approval and failures,
and opens an indexed Codex chat through `codex://threads/<id>`. This deep link
requires a desktop installation that registers that route. No conversation
text, command output or credentials are copied into task events. A short session
identifier distinguishes chats without importing titles.

## Test and build results

A finished AI turn means **Turn ended**. Only an explicit verification result can
show **Verified**. Wrap the actual project command with the bundled Zig CLI:

```sh
keyflux check test --label keyflux -- npm test
keyflux check build --label keyflux -- cargo build --release
```

The app/core must already be running. The CLI connects to the same state directory;
for an isolated development app, supply its printed directory **before** `--`:

```sh
./desktop/.build/core/bin/keyflux --state-dir /path/from/dev-launcher \
  check test --label keyflux -- npm --prefix desktop test
```

`--label` is optional, explicitly provided, 1–64 printable ASCII bytes without
whitespace (for example `project-a`). It is never inferred from a private path.
Arguments after `--` pass literally to the executable. Windows requires a native executable; batch files need an explicitly supplied command interpreter. No shell expansion or
output classification takes place. Output stays in the calling terminal. The
child's exit code is preserved; 0 means passed, 1–127 means failed, and 128–255
means cancelled by convention. POSIX signals map to 128 + signal. Windows preserves the native 32-bit exit code; Ctrl+C termination is cancellation, while other native exception codes are failures. A heartbeat
every five seconds proves the wrapper is still observing the process; after 30
seconds without an observation, an unfinished verification becomes unavailable,
not successful or failed. This timeout does not infer an AI phase.

These results cover **only the wrapped command**. Arbitrary commands run by
Codex, unwrapped test processes, GitHub CI and deployment services do not silently
become verified checks. Configure a project's explicit test/build commands to use
the wrapper, or implement [AgentEvent v2](specs/agent-event-v2.md).

A failed verification remains visible and controls the failure signal until
**Viewed** is selected on that exact terminal turn. This only acknowledges the
notification: it never grants approvals, answers a question or changes results.
Pending user actions outrank errors, which outrank ordinary running work. A
successful check never hides another running chat. The finite completion color
only appears when every tracked active task has ended.

Task state and acknowledgements are memory-only. On core restart the Codex
adapter reconstructs currently observable activity; old results are not replayed
as fresh completions. An already-running check wrapper does not reconstruct a
lost core's start event; if result delivery fails it reports that failure to
stderr and preserves the child exit code. Persistent verification history and
CI adapters are outside this change.

## Lighting actions

[Theme v3](specs/theme-v3.md) adds an independent action to each main-zone state:

| Action | Kick75 firmware mode | Behavior |
| --- | --- | --- |
| `solid` | 3 | Constant color |
| `marquee` | 6 | Horizontal wave / flowing light, not a custom snake path |
| `orbit` | 10 | Rotating vortex, not a custom perimeter-only frame sequence |
| `blink` | 9 | Firmware glisten / scattered blinking, not whole-board synchronous strobe |

Speed is 1–5 from slow to fast. For native effects, wire speed is `5 - speed`,
direction is 0 and multicolor is disabled. Existing solid-mode speed/direction
bytes stay unchanged. All defaults remain solid. The editor's animation is an
illustration and respects reduced motion; it is not an optical simulation of
firmware timing.

Each transition uses a single main-only D6 configuration write, then D5 readback.
The firmware keeps animating without host frame writes. Exact capture, device
binding, concurrency checks, readback, crash journal and restore behavior are
shared with constant colors. Side bytes are never written. Unknown devices,
firmware and profiles remain blocked. No new raw HID commands, palette writes,
per-key capability or wireless support are introduced.

Mode meanings were inspected as protocol facts in NuPhy IO's public
`main.eff2c3e9.js` (SHA-256
`b247cc2093d77cf5d5f6fb7c76c8d7d2f4792e525f5ccc797a8b60274f95c6ac`)
on 2026-10-27. The bundle is not redistributed or used as implementation code.
Software tests validate mode encoding, direct/HSV readback, side isolation and
restoration. New effects still require visual validation on the physical
Kick75 before being called verified. Flash persistence and lifecycle release
gates documented in [hardware validation](hardware/kick75.md) remain open.

Run software checks with `python3 tests/workflow.py zig-out/bin/keyflux` and
`./scripts/dev-macos.sh --check`. The workflow test uses a temporary IPC namespace
and real child processes, never HID or user configuration.
