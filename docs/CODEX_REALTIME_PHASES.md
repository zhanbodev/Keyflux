# Codex phase events: availability gate, 2026-10-27

**Result: real phase callbacks exist, but a usable real-time subscription for
this installed Desktop App has not been established. Thinking/output integration
is not complete. Production lighting continues to use the verified coarse local
source; the delayed diagnostic-log prototype is not enabled or shipped.**

Environment: ChatGPT **26.1021.31345 (21828)**, local Codex
**0.164.0-alpha.11.1**, Apple Silicon macOS. Reference source is the nearby public
`rust-v0.164.0-alpha.11` tag, commit
`fd591b6049c2745a2097baab41180fbdb19bdac0`. Installed behavior was inspected
separately; the public commit is not claimed as the exact Desktop binary build.

## What was confirmed

| Candidate | Evidence | Decision |
| --- | --- | --- |
| App Server notifications | Official `item/started`, `item/reasoning/summaryTextDelta`, `item/reasoning/textDelta`, `item/agentMessage/delta`, `item/completed`; thread, turn and item identity | Correct event semantics; no accessible subscription to the existing App process was found |
| Current Desktop transport | Three running App Server processes use `--listen stdio://`; no public control-socket candidate was found | Do not tap another process's pipes or replace the current Desktop sessions |
| Rollout JSONL | Persistence policy explicitly excludes ItemStarted and reasoning/message deltas | Keep completed records as coarse activity; do not call them live phases |
| Outgoing-notification diagnostic log | Message-delta records exist, but observed records lack thread/turn IDs | Cannot associate parallel conversations reliably |
| `logs_2.sqlite` item logs | Matching `OutputItemAdded`/completed item records include thread, turn and item identity | Structural evidence, but the diagnostic queue batches up to 512 records or flushes on a default 10-second interval |
| OTel SSE | Code logs event.kind and conversation.id | Candidate for a separately validated SSE client; export is asynchronous |
| OTel WebSocket | This source version records per-kind counters/histograms; default metric tags omit conversation/turn identity | Cannot assume enabling the existing OTLP log receiver delivers current App WebSocket phase events |
| Desktop host text logs | Recent files did not contain the correlated phase start/delta records | No usable immediate-file feed established |

The core's explicit phase contract remains valid. The missing part is a timely,
correlated source for the App's existing sessions, not a color mapping or timer.

## Live observations and rejected prototype

A read-only experimental normalizer followed version-matched model-item logs.
One 20-second probe observed real tool/working/thinking aggregates. Its maximum
observed new-record delay was **10,807 ms**. Another 20-second probe observed only
tool/working, despite matching start/completion records arriving. A shorter
sample's maximum was **2,340 ms**. These are diagnostic-file observation delays,
not P95 or model-to-keyboard measurements. They do not certify real-time behavior.

The standalone reproducible developer probe then observed **5** newly written
phase records in **12 seconds**, with a maximum observation delay of
**9,523.929 ms**. Its [sanitized gate record](evidence/codex-realtime-phase-gate-20261027.json)
keeps this failed acceptance result explicit. It does not inspect root-session
liveness and cannot certify an active AI phase or physical keyboard response.

The underlying log queue defaults to **2048 entries**, batches at **512** and
flushes every **10 seconds**. Ten seconds is a configured interval, not a latency
upper bound; scheduling and queue pressure can add delay or lose records.
Completed short phases may arrive together, after their useful display window.
Polling the same database every 100 ms does not remove producer buffering.

The experimental controller was removed from the production path. No Codex
configuration, hooks, log level, model transport, credentials or App binary was
changed. The normal Keyflux App keeps its existing working/tool/attention/terminal
behavior. There is no elapsed-time, token-count or silence-based phase inference.

A real-time adapter needs a supported event transport from the same App-owned
session, exact thread/turn/item correlation, start/end semantics, bounded loss
handling, and measured source-to-observer delay. A separately started App Server
is a separate runtime and does not by itself subscribe to the App's private stdio
stream. An official observer/extension feed or an officially supported shared
transport would need to be established before enabling these states.

## Reproducible read-only developer probe

```sh
python3 scripts/probe-codex-phases.py --inspect-transports
python3 scripts/probe-codex-phases.py --observe-seconds 20 --inspect-transports
python3 scripts/probe-codex-phases.py --assert-realtime
```

The last command exits **2** for this rejected diagnostic-log candidate. JSON
output contains structural counts and optional transport counts, never source
bodies, session/turn/item IDs, private paths, process arguments or credentials.
`--output FILE` writes only the report. `--home PATH` supports an isolated fixture.
This Python script is a development diagnostic, not an App runtime dependency.

## Wireless boundary

Codex status monitoring does not need a USB keyboard. Real Kick75 lighting in
Keyflux currently uses the verified USB-only S4 interface. Bluetooth/2.4 GHz RGB
write/readback/restore is not implemented or verified. A keyboard's own firmware
lighting can continue wirelessly; it does not mean Keyflux is updating its colors.

NuPhy Lab's Bluetooth support covers input shortcuts and offline editing, while
its documented app-controlled RGB/status colors still require USB. Its Air75 V3
Bluetooth descriptor does not establish Kick75's wireless protocol. Do not infer
either universal wireless support or permanent impossibility for Kick75.

## Primary sources

- [Official App Server events and transports](https://learn.chatgpt.com/docs/app-server)
- [Official OTel behavior and asynchronous export](https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry)
- [Model-stream item starts and deltas](https://github.com/openai/codex/blob/fd591b6049c2745a2097baab41180fbdb19bdac0/codex-rs/core/src/session/turn.rs)
- [Completed-item logging context](https://github.com/openai/codex/blob/fd591b6049c2745a2097baab41180fbdb19bdac0/codex-rs/core/src/stream_events_utils.rs)
- [Rollout persistence exclusions](https://github.com/openai/codex/blob/fd591b6049c2745a2097baab41180fbdb19bdac0/codex-rs/rollout/src/policy.rs)
- [Diagnostic SQLite batching](https://github.com/openai/codex/blob/fd591b6049c2745a2097baab41180fbdb19bdac0/codex-rs/state/src/log_db.rs)
- [SSE logs, WebSocket metrics and metadata tags](https://github.com/openai/codex/blob/fd591b6049c2745a2097baab41180fbdb19bdac0/codex-rs/otel/src/events/session_telemetry.rs)
- [NuPhy Lab Bluetooth verification](https://github.com/NuPhyLab/Air75-V3-RGB-Lab/blob/main/docs/BLUETOOTH.md)
