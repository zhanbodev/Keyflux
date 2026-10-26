# KeyboardPreview v1

Screen geometry is independent of HID addressing. A key rectangle is not an LED index, and rendering a model never enables hardware support.

Layouts live in `assets/keyboard-layouts/<model-id>.json`. The React registry imports reviewed layouts at build time. Run the validator before adding a model. The retained SwiftUI resources are historical snapshots, not the active catalog. No external binary plugins are loaded.

```json
{
  "schema_version": 1,
  "id": "example-keyboard",
  "name": "Example keyboard",
  "preview_only": true,
  "width": 3,
  "height": 2,
  "keys": [{"id":"escape","label":"ESC","kind":"key","x":0.5,"y":0.5,"w":1,"h":1}],
  "lights": [{"id":"left","zone":"side","x":0.1,"y":0.5,"w":0.1,"h":1}]
}
```

- Housing coordinates use any consistent unit; all values must be finite. Width ≤ 50, height ≤ 20; positive rectangle sizes, nonnegative positions, all rectangles inside the housing.
- 1–128 keys, at most eight light shapes. IDs are unique within each collection. Key rectangles must not overlap.
- `kind`: `key` or `knob`; `label` may contain newlines and is at most 16 characters. Optional `symbol` is a stable semantic icon key, replacing the text legend. Existing SF Symbol-style names remain compatible; the React renderer maps known keys to reviewed static icons. New icon keys require a compiled registry change.
- `lights[].zone` is currently only `side`. All supplied strip apertures share the state-specific side signal. Separate left/right configuration is not implemented.
- `preview_only:true` identifies a layout example, not a supported device. Air75 V3 is explicitly an approximation/example; Kick75 key geometry comes from the user-supplied NuPhy IO DOM.
- Optional `note` records scope/provenance; optional `source_sha256` identifies the source fragment without publishing user paths or the original page.
- Files are UTF-8 JSON. Maximum file size is 128 KiB. No URLs, HID commands, LED indices, scripts or stylesheets are accepted.

[JSON Schema](../../schemas/keyboard-preview-v1.schema.json) covers structure; the validator additionally checks housing bounds, unique IDs and overlap:

```sh
python3 scripts/validate-keyboard-previews.py
python3 scripts/validate-keyboard-previews.py path/to/model.json
```

## Importing a NuPhy IO element

```sh
python3 scripts/import-nuphy-preview.py element.html \
  --id nuphy-kick75-io --name 'Kick75 IO' --output layout.json
python3 scripts/validate-keyboard-previews.py layout.json
```

The importer reads `myKeyBoardBac` dimensions and `boxBacOut` rectangles/legends, normalizes rem coordinates, and maps known icon references to system symbols. It never executes the fragment or imports image URLs, page controls, account data or JavaScript. Missing dimensions or unknown key icons fail the import. The supplied Kick75 fragment yielded **81 key/control elements**, including the rotary control, F14/F15 and multi-line legends.

The fragment references external shell images and CSS masks and does not describe the actual side strips. The Tauri App uses the original static shell, segmented key masks and known sprite symbols from a hash-verified local reference cache. No third-party website scripts execute. Side-strip placement remains illustrative; font rendering may differ from the original website. See [desktop assets and provenance](../DESKTOP.md). These limits are recorded rather than treating an HTML screen position as verified firmware topology. Contribute a more accurate screen shape with model-specific evidence; per-key hardware mapping requires separate protocol evidence.

The keyboard preview and white console share a fixed viewport grid; preview size adapts to the available height, without sticky layers or page scrolling. Selecting a state or editing RGB/brightness updates it immediately. Main and side signals are rendered separately; following the core's phase is optional. Saving, importing/exporting and changing preview models never writes real HID.

DOM imports now leave `lights: []` when the fragment supplies no strip geometry. Do not fabricate outer bars; add model-specific aperture geometry only with a reference. The UI label is “条形灯”; the versioned JSON zone remains `side` for compatibility.
