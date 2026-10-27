# Theme v3: verification palettes and main-zone actions

Status: draft. [JSON Schema](../../schemas/theme-v3.schema.json),
[complete example](../../examples/theme-v3.json).

v1/v2 files remain readable. Import explicitly upgrades the editor's working
copy to v3, preserving existing colors, brightness, side preferences and hold
interval. Only Save persists that upgrade. v1/v2 exports never gain new fields;
old cores reject version 3 rather than reinterpret it.

v3 retains v2 fields and adds `checking`, `verified`, `check_failed` to both
palettes plus optional/null `actions` for the **main zone only**. Each action key
is a phase, and each value is `{ "effect": "solid", "speed": 3 }`.
Effects: `solid`, `marquee`, `orbit`, `blink`. Speed: integer 1–5.
Omitted action/state entries receive explicit defaults; all default actions are
solid. Unknown fields/effects, non-integer/out-of-range speeds and invalid colors
are rejected. Side colors retain their v2 meaning and physical side control
remains unavailable.

Default new colors at 50% brightness: checking `#6366F1`, verified `#22C55E`,
check_failed `#F43F5E`. Ordinary AI completion is still **Turn ended**, never a
claim that tests passed. `completion_hold_ms` applies to terminal success
indications only when all tracked active work has ended. Failures remain until
the corresponding terminal task is acknowledged or replaced by its next turn.

A core status reply now advertises `theme_schema_versions: [1,2,3]` and an
`action` resolved for the current phase. Runtime driver capabilities expose `native_main_effects`; the frozen keyboard model-v1 schema is unchanged. The native desktop follower deduplicates
color, brightness, effect and speed together. Unsupported device capabilities
must never be emulated through unsafe sustained configuration writes. See
[native action semantics and verification boundary](../P0_WORKFLOWS.md#lighting-actions).

New errors: `ActionsRequireThemeV3`, `SignalsRequireThemeV3`, `InvalidSpeed`.
