# Extension Interface Specification

2026-10-27: [AgentEvent v2](specs/agent-event-v2.md) and [Theme v3](specs/theme-v3.md) explicitly extend the draft contracts for P0 verification and main-zone actions. Existing v1/v2 inputs remain supported; new fields require the new version. See [P0 workflows](P0_WORKFLOWS.md).


**English** | [简体中文](EXTENSIONS.zh-CN.md)

Status: **v1 draft for Keyflux v0.1**. This document describes the implemented extension surfaces and contributor obligations. Sections marked **planned** are design boundaries, not callable APIs. The Zig types and validators are the executable source of truth; JSON Schemas cover structural validation but cannot express every cross-field or lifecycle rule.

## Extension surfaces

```text
AI source → adapter → AgentEvent v1 → state aggregation
                                         ↓
                                  Theme v1/v2 / renderer (planned)
                                         ↓
                               KeyboardDriver → HID transport
```

| Surface | Contract / source | Integration today |
| --- | --- | --- |
| AI adapter | [AgentEvent schema](../schemas/agent-event-v1.schema.json), [event.zig](../src/event.zig) | CLI or local IPC; any implementation language |
| Keyboard model | [Keyboard schema](../schemas/keyboard-v1.schema.json), [device.zig](../src/device.zig) | Validated JSON contributed with evidence; no runtime auto-discovery from model files |
| Keyboard driver | `KeyboardDriver` in [device.zig](../src/device.zig) | Compiled Zig source; simulated daemon plus an experimental manual Kick75 CLI driver |
| Color theme | [Theme v1](../schemas/theme-v1.schema.json), [Theme v2](../schemas/theme-v2.schema.json), [theme.zig](../src/theme.zig) | Versioned main/side configuration, validation, import/export and main-signal hot reload |
| Keyboard preview | [KeyboardPreview v1](specs/keyboard-preview-v1.md) | Shared `assets/keyboard-layouts` geometry; reviewed React registry, separate from HID mapping |
| Desktop bridge | [Internal desktop contract](DESKTOP.md#bridge-contract-internal-v1) | Reviewed local Tauri commands; UI changes do not alter the public CLI/event/driver contracts |
| Animated effect | EffectRenderer, planned for v0.4 | No renderer registration, frame submission, or binary-plugin loader yet |

The core owns task aggregation, lighting ownership, recovery, and device scheduling. An AI adapter never opens HID. A theme never contains hardware commands. A driver never interprets conversation content.

## AI event adapters

### Event envelope

Send one UTF-8 JSON object to `keyflux emit`, either as a file argument or through stdin. Event objects reject unknown fields and have a 16 KiB limit.

| Field | Type | Required / rule |
| --- | --- | --- |
| `schema_version` | integer | Required; `1` |
| `provider` | string | Required; stable adapter namespace |
| `session_id` | string | Required; stable session identity within that provider |
| `turn_id` | string | Required; distinct identity for each root turn |
| `event_id` | string | Required; unique within provider/session/turn; reuse on retry |
| `timestamp_ns` | integer | Required; positive Unix nanoseconds; at most 10 seconds ahead of the core clock |
| `kind` | enum | Required; one of the kinds below |
| `task_id` | string or null | Optional child-task identity within the parent session/turn; absent/null means root |
| `request_id` | string or null | Required and non-null for tool/attention start and resolution events |
| `tool_name` | string or null | Optional structural tool name, without arguments or output |

Identifiers are 1–192 bytes of printable ASCII (`0x21`–`0x7e`), with no spaces. `task_id` cannot begin with `@`. Treat `@current` and `@uncorrelated` as internal Codex-adapter conventions, not general-purpose identities. Emit `timestamp_ns` losslessly as a JSON integer, not a string or a floating-point approximation.

```json
{
  "schema_version": 1,
  "provider": "example.harness",
  "session_id": "session-a",
  "turn_id": "turn-a",
  "event_id": "event-1",
  "timestamp_ns": 1,
  "kind": "turn_started"
}
```

The timestamp above is for schema/offline demonstration. A live adapter must generate the source event's actual timestamp.

### Event semantics

| Kind | Meaning |
| --- | --- |
| `turn_started` | Begin a root turn or child task; establishes `working`, not `thinking` |
| `working` | Confirmed ordinary activity with no exposed fine phase; preserve pending requests |
| `thinking` | Explicitly observed reasoning activity |
| `output` | Explicitly observed assistant text output |
| `tool_started` / `tool_finished` | Open/close the same `request_id` |
| `attention` / `attention_resolved` | Mark/resolve waiting for the same `request_id` |
| `turn_completed` | End the root turn or child task; does not certify correctness |
| `turn_cancelled` / `turn_failed` | Explicit interruption / run failure |
| `source_lost` / `source_resumed` | Source unavailable / reconnected; reconnect alone supplies no phase evidence |
| `session_ended` | End and clean up the current root turn |

Root turns must start before phase events. Each provider/session has one current root turn; finish it before starting another. Put child events under the parent `session_id` and `turn_id`, with their own `task_id` and explicit start. Child completion does not finish the parent; root termination closes its child tasks.

Preserve source order. Old phase/lifecycle events and ended-turn events return `stale`; duplicate events return `duplicate`; neither advances the revision. Recent event-ID deduplication is bounded, not an unlimited exactly-once guarantee. Reconnect with uncertain state must not fabricate completion or reasoning.

An unresolved tool request keeps the task in `tool` unless attention applies. Resolving attention does not close the associated tool request; send `tool_finished` when the tool actually ends. An unrelated tool result cannot clear another request's attention.

Aggregation precedence is: active attention → recorded error → unavailable source → active work → completion hold → idle. Among ordinary active tasks, the most recent eligible phase wins. A known in-flight tool request overrides its task's ordinary phase. Normal working/thinking/output/tool activity cannot be hidden by another session's completion. Unknown and idle release the simulated lighting lease.

Current bounds are 64 sessions, 8 tasks per turn including the root, 8 pending requests per task, and 256 recent deduplication digests. At session capacity, only the oldest ended tombstone can be recycled. A retirement timestamp watermark rejects historical starts. Active sessions are never evicted; full active capacity is an error. The core does not persist active tasks. The local Codex adapter revalidates writer ownership and structural observations after restart; other adapters own their source-availability detection.

Draft revision 2026-10-27 adds `working` without changing existing meanings. Older cores reject this new kind; explicitly upgrade the core with an adapter that uses it. See the [event notes](specs/agent-event-v1.md).

### Minimal any-language adapter example

With `keyflux serve --simulate` running, this Python example submits **synthetic demonstration events** using the same public CLI a real adapter would call. Set `KEYFLUX_BIN` to the executable path if it is not on `PATH`; use the same `--state-dir` on server and client when isolating an instance.

```python
import json
import os
import subprocess
import time
import uuid

binary = os.environ.get("KEYFLUX_BIN", "keyflux")
session_id = "demo-" + uuid.uuid4().hex
turn_id = uuid.uuid4().hex

def emit(kind):
    event = {
        "schema_version": 1,
        "provider": "example.harness",
        "session_id": session_id,
        "turn_id": turn_id,
        "event_id": uuid.uuid4().hex,
        "timestamp_ns": time.time_ns(),
        "kind": kind,
    }
    result = subprocess.run(
        [binary, "emit"], input=json.dumps(event),
        text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)

emit("turn_started")
emit("thinking")
emit("output")
emit("turn_completed")
```

In a real adapter, call these transitions only from corresponding source callbacks. Do not synthesize phases using timers or prompt keywords. Document the provider namespace, source version, supported phases, child-task mapping, unavailable states, disconnect detection, and measured latency in the contribution. This is contribution metadata, not an additional runtime manifest format.

### Local IPC and errors

CLI is the recommended integration boundary. The internal IPC envelope for an event is:

```json
{"op":"emit","event":{"schema_version":1,"provider":"example.harness","session_id":"session-a","turn_id":"turn-a","event_id":"event-1","timestamp_ns":1,"kind":"turn_started"}}
```

```json
{"ok":true,"result":"applied","state":{"phase":"working","active_tasks":1,"tracked_sessions":1,"revision":1}}
```

macOS: the instance's `control.sock`, in a `0700` directory; one newline-delimited JSON request and response per connection. Windows: a user-ACL-restricted named pipe derived from the instance directory; the native client acknowledges receipt with byte `0x06` after the response newline, before disconnect. The pipe naming scheme is internal; prefer CLI over hardcoding it. Local control IPC is not an HTTP API, and `emit` is not exposed at the OTLP HTTP endpoint.

| Operation | Additional request fields | Success data |
| --- | --- | --- |
| `status` | None | `result`: aggregate state, backend, evidence counters, process metrics |
| `emit` | `event` | `result`: `applied`, `duplicate`, or `stale`; aggregate `state` |
| `theme-get` | None | `theme` object |
| `theme-set` | `theme` object | `ok: true` after validation and persistence |
| `preview` | `phase`, optional `signal` (`color`, `brightness`) | Simulated preview for 3000 ms; no theme save |
| `reset` | None | Clears tasks/preview/device error and attempts simulated restoration |
| `stop` | None | Acknowledges shutdown request; the process then attempts restoration |

Read `backend` together with `main_write_enabled`: `true` on the simulated backend does not mean physical writes are enabled. `release_ready` remains false in this internal build. A `stop` response acknowledges a request, not completed hardware recovery.

Errors use `{"ok":false,"code":"ErrorName"}`. CLI operations exit nonzero on failure; inspect the exit status before decoding a success object. The Codex `hook` command is intentionally fail-open and emits `{}` even if the daemon is unavailable. It is not the general adapter submission API.

| Error group | Examples | Caller action |
| --- | --- | --- |
| Contract | `UnsupportedVersion`, `InvalidIdentifier`, `ReservedIdentifier`, `MissingRequestId`, `PayloadTooLarge` | Fix the payload; do not retry unchanged |
| Lifecycle | `MissingTurnStart`, `TurnStillActive`, `UnknownTask`, `FutureEvent` | Reconcile identity, ordering, and source clock; do not invent a start |
| Capacity | `SessionCapacity`, `TaskCapacity`, `RequestCapacity` | Report the limitation; avoid unbounded retries or silent resets |
| Runtime | `DaemonUnavailable`, `HardwareGateNotPassed`, `StateWriteFailed` | Surface availability/failure; retry only after reconciliation |

The optional OTLP endpoint is a separate, authenticated Codex observation path. Its supported record fields, content types, size limits, and actual-version validation procedure are in the [Codex guide (Chinese)](CODEX.md).

## Keyboard models and drivers

### Model descriptor

Contribute models under `models/`. The [existing Kick75 descriptor](../models/nuphy-kick75-io.json) is an experimental, firmware-specific example, not proof that a related model supports the same lighting protocol.

| Field | Contract |
| --- | --- |
| `schema_version`, `id`, `name` | Version `1`; ASCII identifier; display name of 1–128 UTF-8 bytes |
| `protocol` | Currently only `nuphy_io_s4`; new protocols require code/schema changes |
| `usb` | Decimal `vendor_id`, `product_id`, `usage_page`, `usage`, `report_bytes`; optional `interface_number` (default `-1`, unspecified) |
| `firmware` | Optional `family` (default `unknown`) and exact `versions` list (default empty) |
| `verified_on` | Optional matrix of `platform`, `architecture`, `firmware`, `profile`, `transport`, `zone`, and `evidence` |
| `layout` | Optional/null physical mapping: `key_count`, `led_count`, `leds` |
| `capabilities` | `solid_main`, `per_key`, `readback`, `restore`, `max_frames_per_second`; absent members default to false/zero |
| `verification` | `recognized`, `experimental`, or `verified` |
| `evidence` | Required array of protocol/validation references; nonempty for `verified` |

USB VID/PID must be nonzero 16-bit values. `report_bytes` is currently fixed to 64; `interface_number` is `-1` or 0–32767. No scripts, opcodes, library paths, or firmware images belong in a descriptor.

`recognized` forbids `solid_main`, `per_key`, and `restore`. `verified` requires nonempty evidence, exact firmware versions, and `verified_on` entries. Matrix platforms are `macos`/`windows`, architectures `aarch64`/`x86_64`, profiles `mac`/`win`, transport `usb`, and zone `main`. Every matrix entry needs evidence and a firmware version listed in `firmware.versions`. Verification is scoped to those combinations, not all firmware for a product name.

For a per-key descriptor, `solid_main` must be true, `max_frames_per_second` must be positive, and layout is required. Each LED entry has `id`, `index`, `x`, `y`; IDs and indices are unique, coordinates finite and nonnegative, and indices less than `led_count`. `key_count` must equal the mapping length (1–256); `key_count ≤ led_count ≤ 1024`. Leave unlocated channels unmapped rather than inventing physical positions.

```sh
keyflux diagnose
keyflux validate-model models/nuphy-kick75-io.json
```

`diagnose` enumerates HID identities without opening a device or sending lighting reports. `validate-model` validates a file; it does not install, discover, or activate a driver. JSON Schema alone does not check unique LED indices or firmware-list membership; run the CLI validator too.

### Driver source contract

Implement the actual vtable in [device.zig](../src/device.zig), compiled with Zig 0.17.0:

```zig
pub const VTable = struct {
    probe: *const fn (*anyopaque) anyerror!Identity,
    capabilities: *const fn (*anyopaque) Capabilities,
    capture: *const fn (*anyopaque) anyerror!Capture,
    setSolid: *const fn (*anyopaque, Lighting) anyerror!void,
    restore: *const fn (*anyopaque, Capture) anyerror!void,
    setSideSolid: ?*const fn (*anyopaque, Lighting) anyerror!void = null,
};
```

`Identity` contains `model_id`, `firmware`, `profile`. `Lighting` contains byte RGB and integer brightness 0–100. `KeyboardDriver` holds the context pointer and vtable; the driver owner must keep context and borrowed identity strings alive while outstanding captures reference them. `Simulated` is the runnable source example, not a real HID driver template with safe physical settings.

Contributors must implement these lifecycle guarantees:

1. Probe without taking lighting ownership; declare only independently verified capabilities.
2. Capture the complete state that will be modified. The runtime must durably journal it **before** any mutation; using `Lease` alone does not persist a journal.
3. Serialize access through the core, validate brightness/ranges, honor documented write limits, and leave side lights/keymaps/firmware outside the operation.
4. Publish acknowledgement only after the declared verification step. A transport ACK alone is not physical-light validation.
5. Restore the matching device/firmware/profile, verify restoration, and retain the journal on failure or disconnection. Do not blindly replay an uncertain write.

`Capture` now adds an optional compiled `native` tagged union; `null` preserves the existing simulation representation. The `nuphy_s4_main_v1` variant contains `fingerprint: [64]u8` and complete `state: [17]u8`. RGB/brightness alone cannot restore a factory effect. New protocols must add reviewed source variants and tests; never put arbitrary report commands in captures or model files.

The [Kick75 driver](../src/kick75.zig) implements the same vtable. Its manual CLI uses a separate `kick75-recovery.json` journal with explicit `schema_version: 1`, `format: kick75-s4-main-v1`, original probe/raw state, expected state and a `pending` transaction marker. The original fingerprint, firmware and profile must match; writes begin only after a durable pending record, and a pending transaction blocks further colors until explicit restore. The CLI never uses the simulated `Lease` journal for a physical effect. The daemon and UI still use read-only/simulation only. See [manual commands, exact quantization/recovery and remaining gates](hardware/kick75.md). There is no public `registerDriver` API or hardware event routing yet.

Errors include `UnsupportedCapability`, `DeviceDisconnected`, `ReadbackMismatch`, `IdentityMismatch`, `InvalidModel`, `UnsupportedReportSize`, `UnverifiedCapability`, `MissingEvidence`, `UnlistedFirmware`, `MissingLayout`, `InvalidLayout`, and `DuplicateLed`.

## Color themes

`Theme v1` is importable JSON, not executable code:

```json
{
  "schema_version": 1,
  "name": "Glacier",
  "completion_hold_ms": 5000,
  "signals": {
    "thinking": {"color": "#06B6D4", "brightness": 50},
    "output": {"color": "#8B5CF6", "brightness": 50}
  }
}
```

`signals` may define `working`, `thinking`, `output`, `tool`, `attention`, `complete`, `error`. Omitted entries use built-in defaults. Idle/unknown have no configurable color entry and normally restore the original lighting lease.

- `color`: exactly `#RRGGBB`, case-insensitive hexadecimal.
- `brightness`: integer 0–100.
- `completion_hold_ms`: integer 1000–60000; default 5000.
- `name`: 1–64 UTF-8 bytes; default `Keyflux`.
- `schema_version`: `1`; the current parser also defaults an omitted value to `1`.
- Unknown fields/versions are rejected; maximum document size is 16 KiB.

```sh
keyflux validate-theme examples/theme.json
keyflux theme-set examples/theme.json
keyflux theme-get
```

Validation/persistence precede hot reload; invalid themes keep the last valid configuration. `theme-get` returns a wrapper containing `theme`; export that nested object for later import. `preview <phase> --signal-stdin` accepts a signal object for a temporary unsaved-color preview on the simulated backend. Previews do not persist theme changes.

Errors include `InvalidColor`, `InvalidBrightness`, `InvalidDuration`, `InvalidThemeName`, `UnsupportedVersion`, and `StateWriteFailed`.

## Animated effects — planned

The intended pure-computation boundary is:

```text
render(state, monotonic_time, layout, capabilities, parameters) → logical_frame
```

This is **pseudocode**, not an existing Zig signature. Frame types, parameters, renderer registration, and `writeFrame` are not implemented. `per_key` and `max_frames_per_second` currently describe future capabilities only.

Future effects must emit logical RGB frames without HID access. The core will own scheduling, write-rate limits, and replacement of stale frames; the driver will translate logical positions to validated device indices. Snake paths must follow verified physical rows, not assumed LED-index order. Devices without verified per-key output must not advertise snake support.

## Compatibility, privacy, and contribution acceptance

Keep event, model, and theme versions explicit. Pre-v1.0 does not permit silently reinterpreting existing fields. Breaking changes to serialized contracts require a new schema version and migration documentation; Zig source interfaces remain tied to the pinned compiler and are not a stable binary ABI. Public event/schema changes must update source, schemas, examples, both README versions, both extension specifications, and relevant tests together.

Adapters may send structural identities, kinds, timestamps, correlation IDs, and tool names only. Never put prompts, message bodies, tool input/output, credentials, serial numbers, or user paths into events or public evidence. Configuration setup must preserve unrelated integrations and make conflicts reviewable. No descriptor, theme, or evidence document can authorize arbitrary hardware commands.

For a contribution, provide:

- Scope, source/protocol provenance, compatible license, and supported capability matrix.
- A minimal example plus validator results; deterministic tests for ordering, duplicates, invalid data, and unsupported capabilities as appropriate.
- For hardware: exact model, USB interface, OS/CPU, firmware, keyboard profile, connection, controlled zone, persistence behavior, write limits, readback, physical observation, restoration, unplug/crash/sleep results, and explicit untested items.
- For AI: real source-version evidence, phase/correlation coverage, missing/ambiguous states, disconnect behavior, and latency measured from source production; synthetic events must stay labeled as synthetic.
- Separate software/simulation results from physical validation. CLI `gate` checks self-reported material and never unlocks a device.

Run `zig build test`, the relevant integration tests, and the appropriate `validate-*` command. See the [contribution checklist (Chinese)](../CONTRIBUTING.md), [validation record (Chinese)](VALIDATION.md), and focused drafts: [events](specs/agent-event-v1.md), [keyboards](specs/keyboard-v1.md), [themes](specs/theme-v1.md) (Chinese).

### Main/side editing and preview extensions

[Theme v2](specs/theme-v2.md) preserves main semantics and adds optional enabled/follow-main/independent side configuration. v1 exports keep their original fields. Side configuration is persisted but not scheduled on hardware; status returns `side_write_enabled:false`. The compiled driver seam adds `Zone`, `solid_side` and an optional `setSideSolid` callback, with default denial and mandatory restoration capability. Native recovery variants and protocol allowlists must be independently extended and verified before activation.

[KeyboardPreview v1](specs/keyboard-preview-v1.md) defines housing bounds, key rectangles/legends/system symbols and side-strip shapes. Contribute JSON plus provenance and validator results. Preview geometry is not a firmware LED index map; a layout or model picker never enables HID control.
