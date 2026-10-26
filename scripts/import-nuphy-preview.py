"""Extract screen geometry/legends from a user-supplied NuPhy IO DOM fragment.

No scripts, images, stylesheets, event handlers or HID/LED indices are imported.
Usage: python3 scripts/import-nuphy-preview.py element.html --id MODEL --name NAME --output layout.json
"""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re

SYMBOLS = {
    "#missioncontrol": "rectangle.3.group", "#search": "magnifyingglass",
    "#siri": "mic", "#macdnd": "moon.zzz", "#mediaKeys_keyIcon6": "backward.end",
    "#mediaKeys_keyIcon4": "playpause", "#mediaKeys_keyIcon7": "forward.end",
    "#mediaKeys_keyIcon3": "speaker.slash", "#mediaKeys_keyIcon1": "speaker.wave.2",
    "#mediaKeys_keyIcon2": "speaker.wave.1",
}


def styles(raw):
    return dict(re.findall(r"(?:^|;)\s*([\w-]+):\s*([\d.]+)rem\s*(?=;|$)", raw))


class Geometry(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.key_depth = None
        self.container = None
        self.key = None
        self.keys = []
        self.text = None
        self.text_depth = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "div":
            self.depth += 1
        if attrs.get("id") == "myKeyBoardBac":
            self.container = styles(attrs.get("style", ""))
        if "boxBacOut" in attrs.get("class", "").split():
            if self.key is not None:
                raise ValueError("Nested key element")
            raw = styles(attrs.get("style", ""))
            self.key = {"x": float(raw["left"]), "y": float(raw["top"]), "w": float(raw["width"]), "h": float(raw["height"]), "kind": "key", "legends": []}
            self.key_depth = self.depth
        if self.key is not None:
            if tag == "p" and "ellipsis" in attrs.get("class", "").split():
                self.text = []
                self.text_depth = self.depth
            if tag == "use":
                ref = attrs.get("xlink:href", attrs.get("href", ""))
                if ref not in SYMBOLS:
                    raise ValueError("Unknown key icon: " + ref)
                self.key["symbol"] = SYMBOLS[ref]
            if tag == "img":
                self.key["kind"] = "knob"

    def handle_data(self, data):
        if self.text is not None:
            self.text.append(data)

    def handle_endtag(self, tag):
        if tag == "p" and self.text is not None:
            text = "".join(self.text).strip()
            if text:
                self.key["legends"].append(text)
            self.text = None
        if tag == "div":
            if self.key is not None and self.depth == self.key_depth:
                self.keys.append(self.key)
                self.key = None
            self.depth -= 1


def extract(source, model, name):
    if not re.fullmatch(r"[a-z0-9-]+", model):
        raise ValueError("Invalid model identity")
    parser = Geometry()
    parser.feed(source)
    if not parser.container or not 1 <= len(parser.keys) <= 128:
        raise ValueError("Missing keyboard container or keys")
    unit = min(key["h"] for key in parser.keys)
    if unit <= 0:
        raise ValueError("Invalid key size")
    keys = []
    for i, key in enumerate(parser.keys):
        result = {"id": f"key-{i}", "label": "\n".join(key.pop("legends")), **key}
        for coord in ("x", "y", "w", "h"):
            result[coord] = round(result[coord] / unit, 6)
        keys.append(result)
    width, height = (round(float(parser.container[k]) / unit, 6) for k in ("width", "height"))
    return {
        "schema_version": 1, "id": model, "name": name, "preview_only": not (Path(__file__).resolve().parents[1] / "models" / (model + ".json")).is_file(),
        "width": width, "height": height, "keys": keys,
        "lights": [{"id": "left", "zone": "side", "x": .19, "y": 2.25, "w": .14, "h": 3.7}, {"id": "right", "zone": "side", "x": round(width-.33, 6), "y": 2.25, "w": .14, "h": 3.7}],
        "note": "Key rectangles/legends extracted from user-provided NuPhy IO DOM. Side-strip positions are illustrative: the fragment does not describe them. No firmware LED mapping or remote artwork.",
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
    }


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("html", type=Path)
    args.add_argument("--id", required=True)
    args.add_argument("--name", required=True)
    args.add_argument("--output", required=True, type=Path)
    options = args.parse_args()
    if options.html.stat().st_size > 2 * 1024 * 1024:
        raise SystemExit("DOM fragment exceeds 2 MiB")
    result = extract(options.html.read_text(encoding="utf-8"), options.id, options.name)
    options.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Extracted {len(result['keys'])} screen keys for {result['id']}")
