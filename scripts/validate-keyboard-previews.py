"""Validate screen-only keyboard geometry; no HID access or LED-index mapping."""
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "macos/Sources/KeyfluxApp/Resources/Keyboards"


def validate(value):
    required = {"schema_version", "id", "name", "preview_only", "width", "height", "keys", "lights"}
    if not required <= value.keys() or value.keys() - required - {"note", "source_sha256"}:
        raise ValueError("Missing or unknown layout fields")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1 or not isinstance(value["preview_only"], bool):
        raise ValueError("Invalid layout version or preview_only flag")
    if not value["id"] or not value["name"] or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in value["id"]):
        raise ValueError("Invalid layout identity")
    width, height = value["width"], value["height"]
    if not (isinstance(width, (float, int)) and isinstance(height, (float, int)) and not isinstance(width, bool) and not isinstance(height, bool) and 0 < width <= 50 and 0 < height <= 20):
        raise ValueError("Invalid housing size")
    if not 1 <= len(value["keys"]) <= 128 or len(value["lights"]) > 8:
        raise ValueError("Invalid element count")
    for collection, fields in [("keys", {"id", "label", "x", "y", "w", "h", "kind"}), ("lights", {"id", "zone", "x", "y", "w", "h"})]:
        ids = set()
        for item in value[collection]:
            if not fields <= item.keys() or set(item) - fields - ({"symbol"} if collection == "keys" else set()) or not item["id"] or item["id"] in ids:
                raise ValueError("Unknown fields or duplicate element identity")
            ids.add(item["id"])
            if "symbol" in item and (not isinstance(item["symbol"], str) or len(item["symbol"]) > 64):
                raise ValueError("Invalid system symbol")
            x, y, w, h = (item[k] for k in ("x", "y", "w", "h"))
            if not all(isinstance(n, (float, int)) and not isinstance(n, bool) and math.isfinite(n) for n in (x, y, w, h)):
                raise ValueError("Invalid rectangle coordinates")
            if not (x >= 0 and y >= 0 and w > 0 and h > 0 and x+w <= width and y+h <= height):
                raise ValueError("Rectangle outside housing")
            if collection == "keys" and (item["kind"] not in ("key", "knob") or not isinstance(item["label"], str) or len(item["label"]) > 16):
                raise ValueError("Invalid key kind or label")
            if collection == "lights" and item["zone"] != "side":
                raise ValueError("Unknown lighting zone")
    for i, a in enumerate(value["keys"]):
        for b in value["keys"][i+1:]:
            if a["x"] < b["x"]+b["w"] and b["x"] < a["x"]+a["w"] and a["y"] < b["y"]+b["h"] and b["y"] < a["y"]+a["h"]:
                raise ValueError(f"Overlapping keys: {a['id']} / {b['id']}")
    return value["id"]


def main():
    files = [Path(p) for p in sys.argv[1:]] or sorted(DEFAULT.glob("*.json"))
    if not files:
        raise SystemExit("No keyboard preview layouts")
    seen = set()
    for path in files:
        if path.stat().st_size > 131072:
            raise SystemExit(f"Oversized layout: {path.name}")
        model = validate(json.loads(path.read_text(encoding="utf-8")))
        if model in seen:
            raise SystemExit("Duplicate model identity")
        seen.add(model)
        print(f"Valid screen layout: {model}")


if __name__ == "__main__":
    main()
