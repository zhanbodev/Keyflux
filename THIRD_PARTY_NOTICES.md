# Third-party components and research sources

## HIDAPI

Vendored, unmodified platform files from [libusb/hidapi](https://github.com/libusb/hidapi), tag `hidapi-0.15.0`. Keyflux elects the BSD-3-Clause licensing option. Copyright holders and full terms are preserved in `vendor/hidapi/LICENSE-bsd.txt` and source headers. File-level Git blob hashes are recorded in `vendor/hidapi/UPSTREAM.json`.

## Protocol and integration research

The core, transport wrapper and S4 codec are independently implemented. The color arithmetic in `src/nuphy_color.zig` is adapted from NuPhy Lab’s MIT implementation; its full license is retained in `licenses/NuPhyLab-MIT.txt` and packaged with the app. Other sources informed protocol boundaries and integration research:

- [NuPhyLab/Air75-V3-RGB-Lab](https://github.com/NuPhyLab/Air75-V3-RGB-Lab), MIT, Copyright (c) 2026 NuPhy Lab contributors. Pinned color reference: `native/HIDBridge.swift` at `9bd300bc6f7eaaad8f766a1a6ef752bbf530088d`. Its byte-HSV model is separately checked against Kick75 `4.0.18.6`; neither Air75 geometry nor setters are reused. Hardware readback and restoration remain exact, not tolerance-based.
- [Pixelmoss/codex-kick75-status-lights](https://github.com/Pixelmoss/codex-kick75-status-lights), MIT, Copyright (c) 2026 zzm. Pinned revision `e32648ee86a8a729734060ac09bd7f8a1213876f`: Kick75 USB identity, 64-byte S4 report description and side-only verification boundary. No side-light controller code is included.
- [NuPhy IO](https://drive.nuphy.io/): official client `main.eff2c3e9.js` and virtual Kick75 data `417.392552f3.chunk.js`, inspected as protocol documentation, not executed or redistributed. Hashes and observed main-light field layout are recorded in `docs/hardware/kick75.md`.
- [OpenAI Codex hooks](https://learn.chatgpt.com/docs/hooks) and [OTel configuration](https://learn.chatgpt.com/docs/config-file/config-advanced): lifecycle schemas and observability capabilities.

[Keyphore](https://github.com/BarryBarrywu/Keyphore), GPL-3.0-only, Copyright (c) 2026 Barry Barry Wu, is a user-facing behavior reference. Its source code, images, Swift components, Rust components and GPL implementation are not bundled, linked or translated into this repository. Keyflux's blue/orange/green state semantics do not claim pixel or waveform equivalence.

NuPhy, Codex, ChatGPT, Claude and DeepSeek remain names of their respective owners. Integration does not imply endorsement.
