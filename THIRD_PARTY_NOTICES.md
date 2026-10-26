# Third-party components and research sources

## HIDAPI

Vendored, unmodified platform files from [libusb/hidapi](https://github.com/libusb/hidapi), tag `hidapi-0.15.0`. Keyflux elects the BSD-3-Clause licensing option. Copyright holders and full terms are preserved in `vendor/hidapi/LICENSE-bsd.txt` and source headers. File-level Git blob hashes are recorded in `vendor/hidapi/UPSTREAM.json`.

## Protocol and integration research

The Keyflux Zig implementation is original. These sources informed protocol boundaries and integration research:

- [NuPhyLab/Air75-V3-RGB-Lab](https://github.com/NuPhyLab/Air75-V3-RGB-Lab), MIT, Copyright (c) 2026 NuPhy Lab contributors. In particular, its restoration and firmware notes establish why Air75 assumptions must not be applied to Kick75 without independent validation.
- [Pixelmoss/codex-kick75-status-lights](https://github.com/Pixelmoss/codex-kick75-status-lights), MIT, Copyright (c) 2026 zzm. Kick75 USB identity, 64-byte S4 report description and side-only verification boundary. No side-light controller code is included.
- [OpenAI Codex hooks](https://learn.chatgpt.com/docs/hooks) and [OTel configuration](https://learn.chatgpt.com/docs/config-file/config-advanced): lifecycle schemas and observability capabilities.

[Keyphore](https://github.com/BarryBarrywu/Keyphore), GPL-3.0-only, Copyright (c) 2026 Barry Barry Wu, is a user-facing behavior reference. Its source code, images, Swift components, Rust components and GPL implementation are not bundled, linked or translated into this repository. Keyflux's blue/orange/green state semantics do not claim pixel or waveform equivalence.

NuPhy, Codex, ChatGPT, Claude and DeepSeek remain names of their respective owners. Integration does not imply endorsement.
