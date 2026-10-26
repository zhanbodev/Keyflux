<p align="center">
  <img src="assets/branding/keyflux-logo-v2.png" alt="Keyflux keyboard logo with colorful keycaps" width="720">
</p>

# Keyflux

**English** | [简体中文](README.zh-CN.md)

A local AI status lighting companion, built around a Zig core for macOS and Windows. Keyflux maps agent activity to keyboard lighting, with separate extension points for keyboards, AI integrations, and visual effects.

**Current stage: v0.1 internal validation. Manual Kick75 IO main-light tests work on macOS / USB / firmware 4.0.18.6 / Mac keyboard profile.** Static colors, exact configuration readback and original-effect restoration passed physical testing. The AI/UI backend remains read-only or simulated; real Codex desktop reasoning/output detection, write persistence and the full device lifecycle are still unverified.

## What works today

- A Zig state engine that aggregates sessions, correlates tool and approval events, and rejects stale events after a turn ends.
- A simulated keyboard with write deduplication, a durable recovery journal, and recovery after forced termination.
- Read-only NuPhy USB HID inventory, plus an experimental Kick75 IO (`19f5:1026`) main-light driver with manual solid colors, exact readback and durable raw-state recovery.
- A Codex hook adapter and an optional authenticated, loopback-only OTLP/HTTP receiver for JSON and protobuf logs.
- A native macOS app with a pinned keyboard preview, model-specific geometry, per-state RGB/brightness editing, and separate main/side palettes. Kick75 uses geometry extracted from the supplied NuPhy IO element; Air75 V3 is a layout example.
- Versioned event, keyboard-model, and theme contracts with validators and contribution guidance.

Thinking requires an explicit reasoning event. Silence, elapsed time, or the absence of tool calls do not establish that phase. Completion means a turn ended, not that its result is correct.

## Platforms and stack

| Component | Technology / current status |
| --- | --- |
| Core | Zig **0.17.0**, pinned in [.zigversion](.zigversion) |
| HID transport | Vendored HIDAPI, BSD licensing option |
| macOS | macOS 13+, Apple Silicon development build; SwiftUI + AppKit settings |
| Windows | x64 core cross-compiles; physical-device behavior is unverified; GUI is planned |
| Local IPC | Unix socket on macOS; user-restricted named pipe on Windows |

Runtime operation needs no Python, Node.js, browser, product account, or model API key. Python is used only for development tools and tests. Basic USB inventory does not require input monitoring or accessibility permissions.

## Quick start

On macOS, install Zig 0.17.0 and Xcode Command Line Tools. Swift 6+ is needed only for the native settings app.

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

### macOS settings app

For local development, build and open an isolated Debug session with one command:

```sh
./scripts/dev-macos.sh
./scripts/dev-macos.sh --demo
```

The launcher builds `.build/macos-dev/Keyflux Dev.app`, starts a simulated core, and connects the UI to a separate development state directory printed in the terminal. `--demo` cycles synthetic working/reasoning/output/tool/approval/completion events. This is a local demonstration, not a Codex connection or physical-light test. Logs stay under `.build/macos-dev/logs`.

Press Ctrl+C in that terminal or quit the menu bar app to stop the development session and its processes. Closing only the settings window keeps it running. Development settings persist between launches, separately from the default application data.

```sh
./scripts/dev-macos.sh --no-build       # Reuse the existing Debug bundle
./scripts/dev-macos.sh --no-ui --demo   # Simulated core and demo, without a window
./scripts/dev-macos.sh --check          # Build, run tests, and exit; requires Python 3
./scripts/dev-macos.sh --help
```

`--check` builds separately under `.build/macos-check` and can run while an existing development instance stays open.

Use `--state-dir /absolute/path` for a custom development instance. Stop the current launcher before starting another. For a manual Swift launch, after building the core:

```sh
swift run --package-path macos --scratch-path .build/macos KeyfluxApp --core "$PWD/zig-out/bin/keyflux"
```

The settings UI uses Simplified Chinese. The top keyboard stays visible while the controls below scroll. Select a preview state (or follow the core), edit the color picker/HEX/brightness, and see main keys and side strips update immediately. Click a key/strip or use the zone tabs to choose what to edit. Side colors can follow the main palette or use independent per-state values.

Themes support Save, undo, presets and import/export. The editor imports v1 and exports explicit [Theme v2](docs/specs/theme-v2.md); a side setting is currently **configuration and screen preview only**. It does not activate side HID writes or AI-driven physical lighting. On normal startup the app connects to an existing core or starts a read-only one, keeping configuration editing available without manually launching a daemon. Closing settings or quitting the settings app leaves the core running; use the power menu or `keyflux stop` to stop it.

To build a local development bundle:

```sh
sh scripts/package-macos.sh
```

The result is `dist/Keyflux.app`, with an ad-hoc development signature. It is not an Apple-notarized distribution. Login items, an automatic installer, and a Windows GUI are not available yet.

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
