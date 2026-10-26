# Theme v2: main and side lighting

Theme v2 adds optional side-light intent. Main lighting keeps the v1 `signals` semantics. The default parser remains v1 when `schema_version` is absent; side configuration requires explicit `schema_version: 2`.

```json
{
  "schema_version": 2,
  "name": "Ice",
  "completion_hold_ms": 5000,
  "signals": {"thinking": {"color": "#06B6D4", "brightness": 50}},
  "side": {
    "enabled": true,
    "mode": "independent",
    "signals": {"thinking": {"color": "#C084FC", "brightness": 35}}
  }
}
```

- `side` may be omitted/null. Its default is no side-light intent.
- `enabled` defaults to false. False preserves the device's original side lighting in a future capable driver; it does not mean “turn LEDs off.”
- `mode`: `follow_main` (default) resolves the selected main signal; `independent` resolves the side's own per-state signal. Changing modes retains the independent palette.
- Both signal maps have the same seven phases, `#RRGGBB` colors and integer 0–100 brightness as v1. Omitted signals take built-in defaults. Disabled/inactive palettes are also validated, preventing hidden invalid data from becoming active later.
- Idle/unknown resolve to no side intent, with restoration required in a future capable backend.
- Document limit remains 16 KiB. Unknown fields/modes/versions and malformed colors are rejected before persistence.

[Schema](../../schemas/theme-v2.schema.json), [example](../../examples/theme-v2.json). `keyflux validate-theme`, `theme-set` and `theme-get` support v1 and v2. A v1 export contains no `side` field; even `side:null` on v1 input is rejected. Older clients can keep using v1 unchanged. The App imports v1 as a draft with side intent disabled and exports explicit v2 when using its editor. Importing does not change the active theme until Save.

## Capability boundary

`Theme.sideSignal()` resolves logical intent only. Current daemons apply main signals to their read-only/simulated backend and **store but do not schedule side writes**. IPC status reports `side_write_enabled: false` and `theme_schema_versions: [1, 2]`. The App checks version support before saving; an older running core must be restarted without discarding the draft. The App previews side colors on screen. No UI action enables real side writes, and `hardware-solid` remains main-only.

The compiled driver seam reserves `Zone { main, side }`, `Capabilities.solid_side` (default false) and optional `VTable.setSideSolid`. `setZoneSolid(.side, ...)` returns `UnsupportedCapability` unless the driver declares side support, has restoration capability and provides that callback. Existing vtables remain source-compatible through defaults. Kick75 and the current simulated driver leave side writes unsupported.

A future driver must add independently verified side protocol access, complete capture/restore for the owned side zone, bounded writes, readback, failure tests and a versioned recovery format. The existing `nuphy_s4_main_v1` capture and nine-byte D6 allowlist do not authorize side writes. Model descriptors only report evidence; setting `solid_side:true` does not activate a backend. The serialized model-v1 capability set remains frozen. Advertising side capability in a descriptor will require a separately versioned model contract; runtime driver capabilities are not model-v1 JSON fields.
