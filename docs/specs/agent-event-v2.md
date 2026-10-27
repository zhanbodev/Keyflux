# AgentEvent v2

Status: draft, explicit successor to [v1](agent-event-v1.md). Existing v1 producers
remain supported unchanged. New producers set `schema_version: 2`; old cores
reject v2. JSON Schema: [agent-event-v2](../../schemas/agent-event-v2.schema.json).
The v1 identity, timestamp, deduplication, capacity, privacy and lifecycle rules
remain applicable. Unknown fields are rejected.

New optional structural fields:

| Field | Contract |
| --- | --- |
| `check_type` | `test` or `build`; required only for the four check lifecycle kinds, otherwise absent/null |
| `attention_kind` | `approval` or `input`; only on `attention`; otherwise absent/null |
| `label` | Explicit project/task label, 1–64 printable ASCII bytes without whitespace; only on root `turn_started` or `check_started` |

New kinds:

| Kind | Meaning |
| --- | --- |
| `check_started` | Start a dedicated root verification turn, display `checking` |
| `check_passed` | Terminal result backed by the verification source, display `verified` |
| `check_failed` | Terminal failure, display `check_failed` until acknowledged |
| `check_cancelled` | Terminal interruption, no success signal |

Checks use an independent provider/session/turn identity, never a guessed parent
AI turn. `task_id` is absent/null. The result must match the start's `check_type`.
Ordinary `turn_completed` / `turn_failed` cannot finish a verification. A result
before start is rejected. Duplicate/late results cannot resurrect a terminal
turn. `working` heartbeats on a running check preserve `checking`; the bundled
wrapper sends them every five seconds. Missing observation for 30 seconds marks
that running check `unknown`; it does not fabricate a failure/completion.

Example: [check-started.json](../../examples/check-started.json). Replace the
fixture timestamp with current Unix nanoseconds and use unique IDs before `emit`.
No prompt, message, stdout/stderr, command arguments or private paths are fields.

## Task queries and acknowledgement

`keyflux tasks` / IPC `{"op":"tasks"}` returns bounded `tasks` records:
`provider`, `session_id`, `turn_id`, optional `label`, `phase`, `ended`, `cancelled`,
`acknowledged`, `updated_ns`, `active_tasks`, `pending_approvals`, `pending_inputs`,
`pending_other`, and optional `check_type`. Source loss does not erase pending
request identity, but the phase becomes unavailable. Times are Unix nanoseconds;
JS clients must not use floating-point timestamps as exact event identities.

```sh
keyflux acknowledge PROVIDER SESSION TURN
```

Equivalent IPC: `{"op":"acknowledge","provider":"...","session_id":"...","turn_id":"..."}`.
Only terminal turns can be acknowledged. This clears their persistent failure
signal without rewriting their outcome. Active approvals cannot be acknowledged
away. The source must send a matching `attention_resolved` or tool result.
Acknowledgements and task state do not persist across a core restart.

New errors: `EventRequiresV2`, `InvalidCheckEvent`, `InvalidAttentionKind`,
`InvalidTaskLabel`, `TaskStillActive`, `ExpectedTaskIdentity`,
`ExpectedCheckCommand`, `InvalidCheckType`, `CheckLaunchFailed`.

Adapters must still declare real source coverage. Current local Codex support
classifies an explicit `request_user_input` tool as `input` and explicit approval
records as `approval`. Records lacking correlation cannot create a fictitious
waiting request. The App's streaming Thinking/output gate remains unpassed.
