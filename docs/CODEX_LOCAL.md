# Codex Desktop local source

The App starts the native reader automatically. Connect a supported USB keyboard
in Keyflux to follow the resulting real state. No Codex CLI session, hooks trust,
API key, telemetry configuration, prompt injection or new AI request is needed.
This integration observes existing local Desktop sessions.

## Source and boundaries

The Rust source adapter uses the read-only index / incremental JSONL / live-writer
approach from NuPhy Lab, revision
`9bd300bc6f7eaaad8f766a1a6ef752bbf530088d` (MIT). The full notice is in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). SQLite is bundled; the App
requires no external sqlite3, Python or Node installation. State aggregation,
themes, device protocol and durable recovery remain in Zig.

- Resolve `CODEX_HOME`, otherwise the current user's `.codex` directory.
- Open the newest numeric `state_*.sqlite` with SQLite READ_ONLY and query_only.
  Select IDs and rollout paths only. Accept `Codex Desktop`, known desktop source
  values and root user/agent-created threads. CLI, guardian and subagent rows are
  excluded. Required columns are checked; unknown schemas report unavailable.
- Resolve event paths under the same home. No other paths are read as rollouts.
- Track at most 48 conversations; already tracked active conversations take
  priority. Child records are not independent sessions; root lifecycle governs
  the parent activity. This is local-machine scope, not remote/cloud coverage.
- Read complete appended JSONL records in order, buffering partial lines. Each
  record is limited to 1 MiB and each file to 4 MiB of IO per poll. Startup reads
  the last 4 MiB, searching backwards up to 32 MiB only if correlation is missing.
  Replacement/truncation invalidates continuity. Aggregate retained fragments
  are limited to 4 MiB plus at most one in-flight record.
- Deserialize only structural fields. Prompt, answer, reasoning content, tool
  arguments/results and account credentials are skipped. No source transcripts,
  titles, private paths or event content are copied into Keyflux diagnostics.
- On macOS inspect existing writer handles using bounded lsof/ps calls, without
  acquiring or modifying locks. A live owner plus an unfinished structural turn
  from that process lifetime establishes ongoing activity during silence.
- Without writer evidence, only recently appended, recently timestamped events
  establish activity (15 seconds); otherwise mark unknown. This fallback does
  not establish a fine phase and has not been accepted on real Windows hardware.

The reader runs independently of the WebView, with a 500 ms pause between polls.
Disk/process inspection adds latency; this is not a 500 ms end-to-end guarantee.
Closing settings keeps monitoring active. Normal Quit restores the keyboard and
stops the owned core. No hooks or exporter configuration is installed.

## State evidence

| State | Evidence / limit |
| --- | --- |
| Working | Explicit turn/context or structural activity, correlated to a live local turn |
| Tool | A correlated function/custom/MCP call without its matching result |
| Attention | Explicit request with ID, including request_user_input; unrelated results cannot clear it |
| Complete | Newly appended explicit turn-completion event; never an old final message |
| Cancel/error | Explicit interruption or run-failure event |
| Unknown | Index/event failure, lost writer, unsupported schema, limit exceeded or backlog |
| Thinking/output | Not emitted by this adapter: current recordings contain completed reasoning/message items, not confirmed live phase starts/deltas |

A tool's own failure does not certify that the whole AI run failed. Desktop-only
approvals that never reach the local records cannot be observed by this adapter.
The generic core still supports real streaming phases from other verified
adapters; its optional hooks/OTLP developer tools remain separate.

The adapter submits `AgentEvent v1` under `codex.desktop.local`. It uses stable
session/turn IDs and timestamped structural observations; raw record timestamps
are used for freshness and process-lifetime checks. Observation time must not be
reported as the model's generation time. Only structural requests reach the Zig
core. Duplicate snapshots do not create repeated HID writes. Historical terminal
records do not light the keyboard; terminal turns cannot be revived by late items.

Source loss emits source_lost, which restores the original effect through the
existing follower. Writer reconnection alone cannot revive the prior state; a
new structural record is required. A distinct core runtime_id causes revalidation
and rebuilding of the current live turns. Archived/removed sessions are cancelled
without creating a completion signal. Per-source limits fail closed.

## Verification

Tested source environment: ChatGPT App **26.1021.31345 (21828)**,
`com.openai.codex`, local Codex **0.164.0-alpha.11.1**, state_5.sqlite,
Apple Silicon macOS. The live read-only test identified two active real Desktop
sessions and the Zig aggregate tool state. A later real-source hardware test
observed working, applied 15% blue to USB Kick75 NuPhyIO **4.0.18.6 / Mac profile**,
confirmed independent D5 readback, preserved the strip bytes, and restored all
17 original configuration bytes on disconnect. It emitted no synthetic AI events.

Deterministic file/index replay separately covers tool/attention correlation,
completion, cancellation, duplicates, late records, source loss/reconnect,
partial/oversized records and replacement. Completion/attention replay is not
claimed as a physically observed live App completion/approval.

Opt-in local checks (never run automatically in CI):

```sh
KEYFLUX_TEST_CORE="$PWD/desktop/.build/core/bin/keyflux" cargo test \
  --manifest-path desktop/src-tauri/Cargo.toml --locked \
  manual_real_desktop_source -- --ignored --nocapture

# Uses the physical keyboard and restores it afterwards.
KEYFLUX_TEST_CORE="$PWD/desktop/.build/core/bin/keyflux" cargo test \
  --manifest-path desktop/src-tauri/Cargo.toml --locked \
  manual_real_desktop_to_kick75 -- --ignored --nocapture
```

Keep a single Keyflux App instance in control of the keyboard. Live streaming
Thinking/output, Work/Chat, Windows writer ownership and hardware, flash
persistence, sleep/wake and the performance targets remain separate gates.
