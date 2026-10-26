<p align="center">
  <img src="assets/branding/keyflux-logo-v2.png" alt="Keyflux keyboard logo with colorful keycaps" width="720">
</p>

# Keyflux

**English** | [简体中文](README.zh-CN.md)

A local AI status lighting companion, built around a Zig core for macOS and Windows. Keyflux maps agent activity to keyboard lighting, with separate extension points for keyboards, AI integrations, and visual effects.

**Current stage: v0.1 internal validation. Manual Kick75 IO main-light tests work on macOS / USB / firmware 4.0.18.6 / Mac keyboard profile.** Static colors, exact configuration readback and original-effect restoration passed physical testing. Automatic AI-driven HID writes remain gated; the desktop App now offers verified manual USB main-light control on macOS; real Codex desktop reasoning/output detection, write persistence and the full device lifecycle are still unverified.

## What works today

- A Zig state engine that aggregates sessions, correlates tool and approval events, and rejects stale events after a turn ends.
- A simulated keyboard with write deduplication, a durable recovery journal, and recovery after forced termination.
- Read-only NuPhy USB HID inventory, plus an experimental Kick75 IO (`19f5:1026`) main-light driver with manual solid colors, exact readback and durable raw-state recovery.
- A Codex hook adapter and an optional authenticated, loopback-only OTLP/HTTP receiver for JSON and protobuf logs.
- A shared Tauri 2 + React/TypeScript settings app with model previews, per-state RGB/brightness editing, main/side palettes and native file dialogs. Kick75 combines extracted geometry with locally cached NuPhy reference artwork; Air75 V3 is a layout example.
- Versioned event, keyboard-model, and theme contracts with validators and contribution guidance.

Thinking requires an explicit reasoning event. Silence, elapsed time, or the absence of tool calls do not establish that phase. Completion means a turn ended, not that its result is correct.

## Platforms and stack

| Component | Technology / current status |
| --- | --- |
| Core | Zig **0.17.0**, pinned in [.zigversion](.zigversion) |
| HID transport | Vendored HIDAPI, BSD licensing option |
| Desktop UI | Tauri 2 + React / TypeScript / Vite; a thin Rust bridge, native tray and system WebView |
| macOS | macOS 13+, Apple Silicon development build; WKWebView |
| Windows | Shared UI and Zig core; WebView2 required; native build/physical testing remains separate validation |
| Local IPC | Unix socket on macOS; user-restricted named pipe on Windows |

Packaged operation needs no Python, Node.js, external browser, product account, or model API key. The UI uses the system WebView; Windows requires WebView2. Node.js and Rust are build dependencies; Python is used for core development tools/tests. Basic USB inventory does not require input monitoring or accessibility permissions.

## Quick start

Install Zig 0.17.0 for the core. The desktop app additionally needs Node.js 24+, Rust stable and platform SDKs (Xcode Command Line Tools on macOS; MSVC build tools and WebView2 on Windows).

```sh
git clone --branch dev https://github.com/zhanbodev/Keyflux.git
cd Keyflux
zig build -Doptimize=ReleaseSafe
zig build test
./zig-out/bin/keyflux diagnose
./zig-out/bin/keyflux replay examples/session.jsonl
./zig-out/bin/keyflux serve --simulate
```

`replay` uses fixed fixture timestamps and prints `working → thinking → output → complete`. `serve --simulate` stays in the foreground and changes only the simulated device.

In another terminal, from the repository root:

```sh
./zig-out/bin/keyflux status
./zig-out/bin/keyflux preview thinking
./zig-out/bin/keyflux theme-set examples/theme.json
./zig-out/bin/keyflux theme-get
./zig-out/bin/keyflux stop
```

Default runtime data locations:

| Platform | Directory |
| --- | --- |
| macOS | `~/Library/Application Support/Keyflux` |
| Windows | `%LOCALAPPDATA%/Keyflux` |

Use `--state-dir PATH` on both the server and clients to isolate an instance. Keep Unix socket paths short. Do not use the dated replay fixtures as live adapter events; generate current Unix nanosecond timestamps and unique event IDs as described in the [extension specification](docs/EXTENSIONS.md#ai-event-adapters).

### Real Kick75 IO main lights (experimental)

```sh
./zig-out/bin/keyflux hardware-probe              # Read-only firmware and light configuration
./scripts/test-kick75-macos.sh                    # Build, show three colors, verify and restore
./zig-out/bin/keyflux hardware-solid '#06B6D4' 15
./zig-out/bin/keyflux hardware-restore
```

Use USB, firmware **4.0.18.6** and the **Mac keyboard profile**; close other lighting clients. The manual test uses 15% brightness, leaves side lights untouched and restores on exit/interruption. A direct `hardware-solid` command stays active until `hardware-restore`. Its original-state journal lives in the default data directory; hardware mutation commands reject `--state-dir` to keep one capture across processes. After an abrupt termination, reconnect the same device/USB port and explicitly restore.

The firmware quantizes RGB; the CLI reports the requested color and `color_quantized`, checks the exact requested or known quantized readback, and restores the original with an exact encoder check. See [protocol, recovery rules and remaining gates](docs/hardware/kick75.md) and [physical test evidence](docs/evidence/kick75-main-20261026.json). Windows/Win profile, flash persistence, sleep/unplug recovery and AI-driven physical changes are not enabled.

### Shared desktop settings app

```sh
npm --prefix desktop ci
./scripts/dev-macos.sh
# Cross-platform equivalent, including Windows:
node desktop/scripts/dev.mjs
```

The launcher builds the Zig sidecar and opens a **real read-only core** in an isolated development directory. The App attempts a read-only USB connection and displays the actual connection result; it never substitutes a simulated device. Click **Connect keyboard** to retry after plugging in USB. Missing hardware leaves the editor available.

The top keyboard has no card background, floating/sticky layer or selectable keys. The white console fits the supported window sizes without page scrolling, with vertical **Main / Light bar** navigation, a compact state list and a custom saturation/value + hue + RGB picker. Menus are app-drawn. Light color follows the original key-outline masks rather than filling the key faces. The old artificial outer gray strips are removed; the optional small right light-bar aperture is a screen illustration only.

On the verified USB Kick75 / macOS / Mac profile / firmware 4.0.18.6 combination, **Apply to keyboard** uses the existing Zig capture, strict readback and restoration path. **Restore effect** restores the captured main configuration; disconnect or normal App Quit restores main lighting owned by this App. Connecting or saving a theme does not change physical colors. Unexpected devices/firmware remain read-only; Windows manual writes remain disabled. Light-bar settings are preview/configuration only. Following agent state currently changes the preview, not real HID.

```sh
./scripts/dev-macos.sh --no-build       # Reuse the built Zig sidecar
./scripts/dev-macos.sh --no-ui          # Real read-only core, no window
./scripts/dev-macos.sh --no-ui --demo   # Explicit synthetic CLI debugging only
./scripts/dev-macos.sh --check          # Software tests; no physical HID writes
sh scripts/package-macos.sh            # Local release .app
```

Close settings to keep the tray/core and any explicitly applied main color running; reopen from the tray. Quit the App or press Ctrl+C to end the supervised session. Recovery journals remain durable after a forced termination; reconnect the same keyboard/port and use **Restore effect**. Bundles live under `desktop/src-tauri/target/{debug,release}/bundle/macos/Keyflux.app`, with a local ad-hoc signature, without Apple notarization.

See [desktop development and command boundaries](docs/DESKTOP.md). The historical SwiftUI implementation in `macos/` is no longer the default UI. NuPhy artwork is a hash-verified, Git-ignored local cache, **not MIT content or cleared public distribution artwork**; see [third-party notices](THIRD_PARTY_NOTICES.md#nuphy-io-preview-artwork).

### Windows core

From a Windows checkout with Zig 0.17.0:

```powershell
zig build -Doptimize=ReleaseSafe
.\zig-out\bin\keyflux.exe serve --simulate
```

Alternatively, cross-compile from the development host:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --prefix zig-out/windows
```

On Ubuntu or another development system, `zig test src/tests.zig` exercises the portable core. Building the macOS runtime requires an Apple SDK; use `-Dmacos-sdk=PATH` when cross-compiling. There is no Linux HID runtime.

## Codex integration

Generate reviewable configuration fragments:

```sh
./zig-out/bin/keyflux setup-codex "$PWD/zig-out/bin/keyflux"
```

This command does not apply configuration. Follow the [Codex integration guide (Chinese)](docs/CODEX.md) to preserve existing hooks/exporter settings, review and trust the hooks, and test the actual desktop version.

Start the optional receiver with `keyflux serve --simulate --otlp-port 4318`. It listens only on `127.0.0.1`; the Bearer token is stored in the instance's `otlp-token` file. Keep that file private. The receiver retains structural event fields, not prompts, conversation text, or tool bodies. No telemetry is automatically uploaded by Keyflux.

Actual desktop event coverage, session correlation, export delay, and automatic source-crash detection remain validation work. Simulated input does not certify these capabilities.

## Extend Keyflux

Start with the **[Extension Interface Specification](docs/EXTENSIONS.md)** ([简体中文](docs/EXTENSIONS.zh-CN.md)). It covers:

| Extension | How to contribute |
| --- | --- |
| Keyboard model | A model descriptor, exact device/firmware evidence, and validation results |
| Keyboard protocol | A compiled Zig driver using `KeyboardDriver`, tests, and recovery evidence |
| AI integration | Any-language adapter emitting `AgentEvent v1` through the CLI/local IPC |
| Color theme | `Theme v1/v2` JSON, validated and imported without recompiling |
| Keyboard preview | [Model geometry](docs/specs/keyboard-preview-v1.md), legends and screen-only light shapes |
| Animated effect | Planned renderer contract; per-key output and snake effects are not implemented |

Keyboard screen layouts have their own [KeyboardPreview v1 contract](docs/specs/keyboard-preview-v1.md) and `python3 scripts/validate-keyboard-previews.py` validator. They do not confer hardware compatibility or per-key addressing.

Descriptors do not execute arbitrary HID commands or automatically activate drivers. There is no external binary-plugin loader or stable plugin ABI. See [CONTRIBUTING.md (Chinese)](CONTRIBUTING.md) for the evidence checklist, and [schemas/](schemas) for machine-readable contracts.

## Validation and roadmap

```sh
zig build test
python3 tests/integration.py zig-out/bin/keyflux
python3 scripts/check-vendor.py
./zig-out/bin/keyflux validate-model models/nuphy-kick75-io.json
./zig-out/bin/keyflux validate-theme examples/theme.json
./zig-out/bin/keyflux gate examples/release-gates.json
```

The last command is expected to exit **2**. It checks self-reported release evidence; it does not unlock a hardware driver. Tests use temporary state, local transports, and simulation. On Windows, pass the built `.exe` path to the integration test.

The recorded simulated benchmark measured about 0.08% of one CPU core at idle, 11.6 MiB resident memory, and 7.8 ms CLI-to-simulated-ack P95. It does not measure real HID, Codex export delay, or physical lighting. See the [validation record (Chinese)](docs/VALIDATION.md) and [raw benchmark](docs/evidence/simulated-performance-20261026.json).

| Version | Milestone |
| --- | --- |
| v0.1 | Internal core, simulation, diagnostics, event probes, and extension contracts |
| v0.2 | macOS Alpha after Kick75 main-light and real Codex phase validation |
| v0.3 | Windows Alpha, native tray/settings, and physical-device validation |
| v0.4 | Verified per-key layouts and snake animation mode |
| v0.5 | Claude Code, DeepSeek/other harness adapters, and community devices |
| v1.0 | Stable contracts, compatibility matrix, migration/recovery, signed releases |

The initial hardware target is one wired USB Kick75 **NuPhyIO** device. QMK/VIA variants, Bluetooth/2.4 GHz lighting, ordinary ChatGPT chat monitoring, and side-light effects are outside the first release. See the [detailed roadmap (Chinese)](docs/ROADMAP.md).

## License

[MIT](LICENSE) © 2026 Nuclx Tech. HIDAPI uses its BSD licensing option. See [third-party notices](THIRD_PARTY_NOTICES.md) for provenance and licensing boundaries. Keyflux is not affiliated with NuPhy, OpenAI, Anthropic, or DeepSeek.
