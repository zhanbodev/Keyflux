"""Regenerate public schemas and reproducible offline examples (development only)."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def save(path, value):
    (ROOT / path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def obj(properties, required=()):
    return dict(type="object", additionalProperties=False, properties=properties, required=list(required))


def schema(name, properties, required=()):
    return {"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": f"https://keyflux.local/schemas/{name}", **obj(properties, required)}


def main():
    colors = dict(working="#3B82F6", thinking="#06B6D4", output="#8B5CF6", tool="#3B82F6", attention="#F97316", complete="#22C55E", error="#EF4444")
    theme = dict(schema_version=1, name="Keyflux", completion_hold_ms=5000, signals={k: dict(color=v, brightness=50) for k, v in colors.items()})
    save("examples/theme.json", theme)
    events = []
    for i, kind in enumerate(["turn_started", "thinking", "output", "turn_completed"]):
        events.append(dict(schema_version=1, provider="codex", session_id="demo-session", turn_id="demo-turn", event_id=f"demo-{i}", timestamp_ns=1700000000000000000 + i * 1000000000, kind=kind))
    (ROOT / "examples/session.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    for name, event in zip(["start", "thinking", "output", "complete"], events):
        save(f"examples/{name}.json", event)
    usb = dict(vendor_id=0x19F5, product_id=0x1026, usage_page=1, usage=0, report_bytes=64, interface_number=3)
    caps = dict(solid_main=False, per_key=False, readback=False, restore=False, max_frames_per_second=0)
    model = dict(schema_version=1, id="nuphy-kick75-io", name="NuPhy Kick75 IO", protocol="nuphy_io_s4", usb=usb, firmware=dict(family="unknown", versions=[]), verified_on=[], layout=None, capabilities=caps, verification="recognized", evidence=["https://github.com/Pixelmoss/codex-kick75-status-lights/blob/main/docs/PROTOCOL.md"])
    save("models/nuphy-kick75-io.json", model)
    gate = dict(schema_version=1, model_id="nuphy-kick75-io", firmware="unverified", platform="macos-aarch64", main_solid_verified=False, restore_verified=False, profile_isolation_verified=False, persistence_understood=False, safe_write_path_verified=False, reasoning_event_verified=False, output_event_verified=False, session_correlation_verified=False, live_codex_desktop_verified=False, end_to_end_p95_ms=None, evidence_files=[])
    save("examples/release-gates.json", gate)

    identifier = dict(type="string", minLength=1, maxLength=192, pattern="^[!-~]+$")
    kinds = ["turn_started", "thinking", "output", "tool_started", "tool_finished", "attention", "attention_resolved", "turn_completed", "turn_cancelled", "turn_failed", "source_lost", "source_resumed", "session_ended"]
    properties = {k: identifier for k in ["provider", "session_id", "turn_id", "event_id"]}
    properties.update(schema_version={"const": 1}, timestamp_ns=dict(type="integer", minimum=1, maximum=18446744073709551615), kind=dict(enum=kinds))
    for key in ["task_id", "request_id", "tool_name"]:
        properties[key] = dict(anyOf=[identifier, dict(type="null")])
    properties["task_id"] = dict(anyOf=[{**identifier, "pattern": "^[!-?A-~][!-~]*$"}, dict(type="null")])
    event_schema = schema("agent-event-v1", properties, ["schema_version", "provider", "session_id", "turn_id", "event_id", "timestamp_ns", "kind"])
    event_schema["allOf"] = [{"if": dict(properties=dict(kind=dict(enum=["tool_started", "tool_finished", "attention", "attention_resolved"]))), "then": dict(required=["request_id"], properties=dict(request_id=identifier))}]
    save("schemas/agent-event-v1.schema.json", event_schema)

    signal = obj(dict(color=dict(type="string", pattern="^#[0-9a-fA-F]{6}$"), brightness=dict(type="integer", minimum=0, maximum=100)), ["color", "brightness"])
    theme_schema = schema("theme-v1", dict(schema_version={"const": 1, "default": 1}, name=dict(type="string", minLength=1, maxLength=64, default="Keyflux"), completion_hold_ms=dict(type="integer", minimum=1000, maximum=60000, default=5000), signals=obj({k: signal for k in colors})))
    save("schemas/theme-v1.schema.json", theme_schema)

    cap_schema = obj({**{k: dict(type="boolean", default=False) for k in ["solid_main", "per_key", "readback", "restore"]}, "max_frames_per_second": dict(type="integer", minimum=0, maximum=65535, default=0)})
    usb_schema = obj({k: dict(type="integer", minimum=1 if k in ["vendor_id", "product_id"] else 0, maximum=65535) for k in usb}, usb)
    usb_schema["properties"]["report_bytes"] = {"const": 64}
    usb_schema["properties"]["interface_number"] = dict(type="integer", minimum=-1, maximum=32767, default=-1)
    usb_schema["required"].remove("interface_number")
    firmware_schema = obj(dict(family=identifier, versions=dict(type="array", items=identifier)))
    verification_schema = obj(dict(platform=dict(enum=["macos", "windows"]), architecture=dict(enum=["aarch64", "x86_64"]), firmware=identifier, profile=dict(enum=["mac", "win"]), transport=dict(enum=["usb"]), zone=dict(enum=["main"]), evidence=dict(type="array", minItems=1, items=dict(type="string"))), ["platform", "architecture", "firmware", "profile", "transport", "zone", "evidence"])
    led_schema = obj(dict(id=identifier, index=dict(type="integer", minimum=0, maximum=1023), x=dict(type="number", minimum=0), y=dict(type="number", minimum=0)), ["id", "index", "x", "y"])
    layout_schema = obj(dict(key_count=dict(type="integer", minimum=1, maximum=256), led_count=dict(type="integer", minimum=1, maximum=1024), leds=dict(type="array", minItems=1, maxItems=256, items=led_schema)), ["key_count", "led_count", "leds"])
    model_schema = schema("keyboard-v1", dict(schema_version={"const": 1}, id=identifier, name=dict(type="string", minLength=1, maxLength=128), protocol=dict(enum=["nuphy_io_s4"]), usb=usb_schema, firmware=firmware_schema, verified_on=dict(type="array", items=verification_schema), layout=dict(anyOf=[layout_schema, dict(type="null")]), capabilities=cap_schema, verification=dict(enum=["recognized", "experimental", "verified"]), evidence=dict(type="array", items=dict(type="string"))), [k for k in model if k not in ["firmware", "verified_on", "layout"]])
    recognized = dict(properties=dict(capabilities=dict(properties={k: {"const": False} for k in ["solid_main", "per_key", "restore"]})))
    verified = dict(required=["firmware", "verified_on"], properties=dict(evidence=dict(minItems=1), firmware=dict(required=["versions"], properties=dict(versions=dict(minItems=1))), verified_on=dict(minItems=1)))
    per_key = dict(required=["layout"], properties=dict(layout=layout_schema, capabilities=dict(required=["solid_main", "max_frames_per_second"], properties=dict(solid_main={"const": True}, max_frames_per_second=dict(minimum=1)))))
    model_schema["allOf"] = [
        {"if": dict(properties=dict(verification={"const": "recognized"})), "then": recognized},
        {"if": dict(properties=dict(verification={"const": "verified"})), "then": verified},
        {"if": dict(properties=dict(capabilities=dict(required=["per_key"], properties=dict(per_key={"const": True})))), "then": per_key},
    ]
    save("schemas/keyboard-v1.schema.json", model_schema)


if __name__ == "__main__":
    main()
