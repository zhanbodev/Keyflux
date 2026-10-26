# Desktop: Tauri 2 + React / TypeScript

Keyflux uses one shared settings frontend, a small Rust desktop shell and the existing Zig core. Rust owns windows, tray menus, native file dialogs and process supervision; it does not implement lighting protocols, session aggregation or recovery. React never opens HID or a network listener.

```text
React / TypeScript → reviewed Tauri commands → fixed Zig CLI operations
                                               ↓
                                    existing Unix socket / named pipe
                                               ↓
                                  Zig core → driver → HIDAPI
```

The previous SwiftUI app in `macos/` is a historical implementation. New UI work belongs in `desktop/`; shared model geometry belongs in `assets/keyboard-layouts/`. Runtime needs no Node.js or Rust installation. macOS uses WKWebView; Windows uses WebView2. The core's CPU/RSS budget does not represent the combined shell and WebView processes; measure those separately before making product-wide performance claims.

## Build and run

Install Node.js 24+, Rust stable, Zig 0.17.0 and the [Tauri platform prerequisites](https://v2.tauri.app/start/prerequisites/). macOS requires Xcode Command Line Tools; Windows requires MSVC tools and WebView2. Use native builds for each platform; a shared frontend is not proof of Windows hardware compatibility.

```sh
npm --prefix desktop ci
node desktop/scripts/dev.mjs
node desktop/scripts/dev.mjs --no-ui --demo
node desktop/scripts/dev.mjs --check
```

`scripts/dev-macos.sh` forwards to the same Node development supervisor. It canonicalizes the isolated state path (the Zig runtime rejects symlinked state directories), refuses to reuse a live instance, starts a read-only core, then launches Tauri/Vite. `--demo` is accepted only with `--no-ui` and emits synthetic structural events; normal development startup uses a real read-only core. `--no-build` skips the Zig rebuild, not the frontend build/hot reload. Ctrl+C or tray Quit ends this development session. It does not signal an older SwiftUI instance or the installed app's core.

```sh
# Native macOS application; local/ad-hoc signature only
sh scripts/package-macos.sh --debug
sh scripts/package-macos.sh
# Native Windows build, from a Windows terminal
npm --prefix desktop run build -- --bundles nsis
```

Artifacts live under `desktop/src-tauri/target/{debug,release}/bundle/`. `prepare-core.mjs` builds Zig and copies its executable to the target-suffixed `externalBin` required by Tauri. The packaged executable is adjacent to the shell (`Contents/MacOS/keyflux` on macOS, `keyflux.exe` on Windows). This was checked in the local macOS bundle. Windows packaging remains subject to the Windows CI/native validation result. Signed/public distribution is still gated by device/Codex validation and artwork rights.

## Bridge contract (internal v1)

App commands are explicitly registered in `src-tauri/build.rs` and granted only to the local `settings` window by `capabilities/settings.json`. There is no generic shell/filesystem/HTTP command and no remote-origin capability.

| Command | Input | Result |
| --- | --- | --- |
| `get_status` | None | Existing `{ok,result}` core response, plus `desktop` instance/ownership metadata |
| `get_theme` | None | Existing `{ok,theme}` response |
| `save_theme` | `{theme: Theme v1/v2}` | Validate with Zig, persist/hot reload via `theme-set` |
| `get_device` | None | Actual connected-session state, periodically re-probed without leaking fingerprint |
| `connect_device` | None | Read-only USB identification and capability check; no physical color mutation |
| `apply_main` | `{model,signal:{color,brightness}}` | Explicit known-device main solid write, with capture/readback and same-device binding |
| `restore_device` | None | Restore and verify the saved original main configuration; reports when no capture exists |
| `disconnect_device` | None | Restore lighting owned by this App before clearing the session |
| `import_theme` | None | Native JSON chooser, bounded read and Zig validation; parsed theme or `null` on cancel |
| `export_theme` | `{theme: Theme v1/v2}` | Zig validation then native save dialog; boolean, false on cancel |

Inputs are limited to 16 KiB; CLI stdout to 128 KiB; each CLI subprocess has a five-second timeout. The trusted executable receives fixed arguments via `Command`, never a shell. Input travels through stdin. Error replies expose stable codes rather than stderr or user paths. React validates for immediate feedback; Zig remains authoritative. Frontend color selection updates local draft state and does not fabricate an AI event. Valid omitted fields and partial palettes are expanded using the core defaults; a v1 side field is still rejected even when null. Theme v1 is explicitly upgraded to v2 by the editor; `theme-get` itself retains the original schema.

The browser entry `?fixture=1` is an explicit UI fixture only. A normal browser cannot silently display a successful core connection. The fixture is visibly labelled and has no HID access. Browser fixture tests do not certify native dialogs, hardware writes, or real provider events.

## Lifecycle

- Packaged startup attaches to an available core in the existing default directory; otherwise it starts a read-only Zig core. Dev mode passes an isolated read-only instance. App startup attempts read-only USB identification; a missing keyboard leaves Connect available. Simulated cores are rejected by the real connection UI.
- Close destroys the settings window/WebView and unmounts polling. The tray and Zig core remain. Settings from the tray creates a fresh WebView and reloads saved themes.
- Explicit Quit first restores any main lighting successfully owned by this App, then requests normal Zig shutdown only for the core owned by this shell. An attached external core stays alive. Zig performs its own recovery. The shell does not force-kill a recovering core.
- The development supervisor owns its core and cleans it up separately. The shell attaches to that core and leaves cleanup to the supervisor.
- If a shell is forcibly killed, the separate core may survive. A subsequent app attaches; a later Quit does not claim ownership of that external core. Use `keyflux stop` when an explicit core shutdown is needed.
- Settings refresh status every 1.5 seconds while visible. This editor refresh is independent of core event-to-device latency and is not a real-time Codex monitoring guarantee.

## Preview resources

`reference-assets.json` records immutable NuPhy IO URLs, extracted symbol IDs and SHA-256 hashes. `npm --prefix desktop run assets:fetch` checks the ignored `desktop/public/reference/` cache, downloads missing resources and extracts literal SVG symbols without executing the website bundle. A hash mismatch fails; it never silently updates trusted art. Delete a cached asset and rerun to reproduce extraction. No original JS bundle is included in the app.

Kick75 uses the actual housing WebP, three-part key masks, knob and media symbols. Absolute screen coordinates come from the supplied DOM. Tint is applied beneath the outline, and wide keys stretch the middle mask. The reference font is unavailable; system font rendering can differ. Side-strip positions remain illustrative. Air75 V3 is an explicitly approximate layout example. None of these screen positions constitutes an HID LED mapping.

NuPhy reference artwork is **not covered by Keyflux's MIT license**. It is cached only for local development, excluded from Git and not cleared for redistribution. A local build includes that cache; do not publish the resulting binary until permission or original replacement artwork is in place. See [third-party notices](../THIRD_PARTY_NOTICES.md#nuphy-io-preview-artwork). The app loads its static resources locally and does not contact NuPhy at runtime.

## Checks

```sh
node desktop/scripts/dev.mjs --check
# Visual/interaction suite (requires the local reference cache)
npm --prefix desktop run assets:fetch
npx --prefix desktop playwright install chromium
npm --prefix desktop run test:ui
```

Alternatively set `KEYFLUX_TEST_CHROME` to an installed Chrome executable. Playwright checks main/side isolation, editing, simulated save, layout switching, asset load and explicit fixture boundaries; screenshots are ignored under `desktop/test-results/`. Rust tests use `KEYFLUX_TEST_CORE` to exercise actual simulated Zig IPC, Unicode v2 save/load, validation failures, restart persistence and core ownership. Normal software checks send no physical HID commands; the explicitly ignored, opt-in hardware test is documented below. CI runs frontend checks and native Rust↔Zig tests on macOS and Windows; remote results must be read before claiming success.


## USB control added with the compact console

Device commands are a separate fixed Rust surface, not generic CLI execution. The normal state/configuration CLI uses the isolated IPC directory; hardware mutations deliberately use the canonical default journal. A connected session retains a private device fingerprint, and `hardware-solid` / `hardware-restore --expect-device <fingerprint>` compare it **after opening the HID device and before capture or mutation**. Changing preview models cannot retarget a write. macOS USB / Mac profile / firmware 4.0.18.6 is the sole writable desktop combination; unknown configurations and Windows are read-only. There is no strip setter or automatic agent-to-HID mapping.

The App serializes probe/apply/restore calls. An initial successful mutation marks its original state for restoration on disconnect/Quit. Closing only the window preserves the session. In-flight writes finish before normal Quit restoration; the closing session rejects new writes. An ambiguous failure retains Zig's recovery journal; reconnect the original device and explicitly restore. A prior external CLI capture is not silently restored just because this App connects or exits.

The actual Rust→Zig bridge was exercised on USB hardware: connect, 15% cyan-green solid, independent D5 readback, exact original 17-byte restoration, with side data unchanged. The opt-in Rust test is ignored by normal CI and requires explicit local execution. A mismatching fingerprint was also verified to reject before mutation.

The custom menus support pointer, arrows, Home/End, Enter/Escape and focus return. The color picker uses RGB in the interface (hex remains only the Theme wire format), keyboard-accessible SV/hue controls, twelve presets and a bounded local recent-color list. The viewport is a fixed grid; the preview scales to the remaining height instead of pinning or scrolling. Screen-only light apertures come from the model catalog and are hidden when disabled, with no gray placeholder bars. The system tray uses a compact colored keyboard mark inspired by the Keyflux logo.
