# Kick75 IO main-light validation

**Status: experimental, manual CLI only.** Tested on 2026-10-26 with a physical USB Kick75 IO, firmware **4.0.18.6**, **Mac keyboard profile**, Apple Silicon macOS. [Redacted evidence](../evidence/kick75-main-20261026.json) records the exact environment, decoded state and results. Windows and Win keyboard profile writes remain disabled. The macOS settings app and AI event pipeline still use read-only/simulated backends.

## Run locally

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/keyflux hardware-probe
./zig-out/bin/keyflux hardware-status  # Same read-only probe plus canonical recovery metadata
./scripts/test-kick75-macos.sh --no-build
```

The script shows red, cyan and purple at 15% brightness for three seconds each, verifies a colored-state restore roundtrip, then restores the initial effect. Watch the keyboard to verify physical appearance. It also restores on normal exit, Ctrl+C, TERM and HUP. SIGKILL, unplugging and power loss cannot run cleanup; the durable journal remains available for an explicit recovery command.

For manual control:

```sh
./zig-out/bin/keyflux hardware-solid '#06B6D4' 15
./zig-out/bin/keyflux hardware-probe
./zig-out/bin/keyflux hardware-verify-restore
./zig-out/bin/keyflux hardware-restore
```

`hardware-solid` keeps its color after the process exits. Further colors preserve the **first** capture. `hardware-verify-restore` re-encodes and restores the current captured color exactly, while keeping the initial recovery journal; it requires an existing journal. `hardware-restore` restores the initial main settings and removes the journal only after exact readback. If there is no journal it reports `restored:false, reason:no_capture` without writing.

Physical mutation commands use one canonical journal: `~/Library/Application Support/Keyflux/kick75-recovery.json`. `--state-dir`, `--simulate` and `--otlp-port` are rejected for those commands, preventing nested captures across isolated instances. A per-user `flock` serializes Keyflux hardware commands across processes. Close other lighting clients; this lock cannot coordinate with third-party clients. Duplicate effective colors do not trigger D6. Unknown firmware, unsupported profiles, custom/off mode `0`, unsupported original fields and unrepresentable restore colors fail closed.

On a pending recovery, reconnect the **original keyboard to the same USB port**, select Mac profile, close competing lighting clients, and run `hardware-restore`. Ownership uses a local SHA-256 fingerprint of USB location and available serial data, plus exact model/firmware/profile checks. Keep the journal on a mismatch; do not copy it to another keyboard. This is conservative port/device binding, not a guarantee of globally unique USB serials. No journal migration or manual identity override is supplied in this internal build.

## Protocol boundary

The independently implemented transport uses HIDAPI in non-exclusive mode and opens only `19f5:1026`, USB, usage page `1`, usage `0`, interface `3`. It verifies a 64-byte input/output descriptor without report IDs. More than one matching device is rejected.

| Command | Length / offset / profile | Purpose |
| --- | --- | --- |
| A1 | 8 / 0 / 0 | Read firmware; derive the existing XOR key from the fixed `0xaa` marker |
| A0 | 8 / 0 / 0 | Read geometry and active keyboard profile |
| D1 | **1** / 0 / 0 | Read LED count (85 on the tested device) |
| D5 | 17 / 0 / active | Read complete main + side configuration |
| D6 | **9 / 0 / active** | Write main configuration only |

No EE key change, D8 palette write, firmware/IAP, reset, keymap, side setter or animation command is sent. The native transport and Zig codec both restrict command shapes. Main writes are pinned to firmware bytes `[18,0,4,170,6,0]`, Mac profile and the observed geometry. Every report checks marker, command, checksum, length, address and profile. A profile change aborts the operation. Transport ACK alone is never published as successful color verification.

D5's 17-byte layout:

| Bytes | Meaning |
| --- | --- |
| 0 | Main mode: `3` is static; side static uses `2` |
| 1 | Main brightness, 0–100 |
| 2 | Encoded speed, preserved |
| 3 | Direction, preserved |
| 4 | Multi-color/RGB flag, `0` for a single color |
| 5 | Color index/reserved slot, currently restricted to `0` |
| 6–8 | Main RGB |
| 9–16 | Side state; captured for diagnostics and isolation checks, never written |

Each write waits 1000 ms before D6, rechecks the configuration for concurrent changes, then waits 150 ms before D5. Blind setter retries are forbidden. D6 ACK failure/readback mismatch attempts a separate original-state restore; unverified recovery retains the journal. The journal is atomically written and fsynced before each mutation with `pending: true`; only exact acknowledgement clears that marker. Its original-state capture stays unchanged. A pending marker blocks additional color commands until explicit restore. After an ambiguous or interrupted transaction, another color cannot replace the original capture; use explicit restore.

## Exact RGB recovery

The tested firmware quantizes RGB through byte HSV. Requested `#8000FF` (`128,0,255`) reads back as `132,0,255`. Merely loosening RGB comparison would hide errors and allow drift during restoration.

`src/nuphy_color.zig` adapts the MIT NuPhy Lab byte-HSV model. Real reconnect testing also observed **direct RGB readback** on the same firmware, including `128,0,255` remaining unchanged after a one-second read-only delay. The internal reason for the two paths is not established. A solid acknowledgement must equal either the exact requested RGB or its exact byte-HSV projection; every other main byte and all side bytes must match exactly. The journal stores the actual acknowledged state, and `color_quantized` exposes whether a transform occurred. No per-channel tolerance is used.

Restoration always requires the **exact saved RGB**, not either color form. It first writes the saved bytes directly. Only a successful ACK followed by the exact known HSV transform permits one different payload: a bounded inverse search finds an input that predicts the saved RGB, then exact hardware readback must pass. Timeouts, transport failures, side changes or unknown values never trigger an encoder retry. Initial capture refuses RGB that is unrepresentable under the HSV model, so a later change to the observed firmware path cannot make that original RGB inherently impossible. Temporary colored-state roundtrip checks remain protected by the initial journal. Prediction is not a substitute for device verification.

Physical calibration matched this model for red, cyan, purple, the default working/thinking/output colors, `#40000E`, black and the original gray. The latter five controlled states each passed a real D6→D5 exact current-state roundtrip without drift on the HSV path; the direct path is recorded separately after reconnect. The final 17-byte configuration matched the initial gradient effect byte for byte. The user also confirmed red/cyan/purple constant appearance, original restoration and unchanged side lights. Configuration readback does not measure optical RGB accuracy or restore an animation's elapsed phase.

## Evidence and outstanding gates

The basic manual color/readback/recovery path passed on the recorded combination. **Release remains blocked** by untested Win profile, Windows physical runtime, D6 persistence/flash behavior, the full unplug/replug lifecycle, sleep/wake and real Codex desktop event/latency coverage. Recurring AI transitions and animations remain gated for public release until safe write persistence and device lifecycle handling are established. The internal desktop follower now has a controlled real-core/USB test; it does not certify App source coverage or flash safety. The one-second delay is an experimental manual limit, not proof of flash-safe sustained operation. The contribution descriptor remains `experimental`.

The 2026-10-27 desktop session pass adds persistent recovery discovery and explicit user-controlled connection with same-device recovery binding. A new Rust session on real hardware detected the first session's saved capture, rejected a new color until explicit recovery, and left that unowned capture intact on shutdown. The original session restored the exact initial 17 bytes after a 15% cyan-green solid and independent readback. Software tests additionally exercise missing/reinserted devices, a changed identity, ambiguous write failure and malformed readback. Physical unplug/replug and sleep/wake were not repeated in that pass. Evidence: [device session integration](../evidence/device-session-20261027.json).

Protocol references were read as documentation, not executed:

- [Kick75 MIT reference](https://github.com/Pixelmoss/codex-kick75-status-lights/tree/e32648ee86a8a729734060ac09bd7f8a1213876f): USB identity and S4 framing; its side-only validation does not establish main support.
- [NuPhy Lab MIT color reference](https://github.com/NuPhyLab/Air75-V3-RGB-Lab/blob/9bd300bc6f7eaaad8f766a1a6ef752bbf530088d/native/HIDBridge.swift): color arithmetic only, independently checked on the Kick75. Full attribution is in [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md) and [MIT license](../../licenses/NuPhyLab-MIT.txt).
- [Official NuPhy IO client](https://drive.nuphy.io/), retrieved 2026-10-26: `main.eff2c3e9.js`, SHA-256 `b247cc2093d77cf5d5f6fb7c76c8d7d2f4792e525f5ccc797a8b60274f95c6ac`; `417.392552f3.chunk.js`, SHA-256 `7725e9d01799132c7317ae0577944871fa095b698cbe4401bede242afe011c09`. These bundles are not redistributed.

A controlled real SIGKILL check terminated the writer after D6 applied and before pending acknowledgement cleared. The next color was rejected with `RecoveryRequired`; explicit recovery restored the initial 17-byte state exactly and removed the journal only after verification. This verifies that interruption point, not all crash timings or unattended reconnect recovery.

Reproduce that **manual hardware** crash experiment (Python is a development dependency only):

```sh
python3 scripts/verify-kick75-crash.py zig-out/bin/keyflux
```

The script refuses a pre-existing capture, kills only its own writer, restores in `finally`, and fails if it missed the applied-write/pending-acknowledgement window. It must never run in unattended CI.
