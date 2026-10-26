"""Contract checks for model contributions and inert NuPhy DOM extraction."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


validator = module("layouts", "validate-keyboard-previews.py")
importer = module("nuphy_dom", "import-nuphy-preview.py")


class PreviewContractTest(unittest.TestCase):
    def setUp(self):
        self.layout = json.loads((ROOT / "macos/Sources/KeyfluxApp/Resources/Keyboards/nuphy-kick75-io.json").read_text(encoding="utf-8"))

    def test_shipped_models_are_distinct_valid_layouts(self):
        other = json.loads((ROOT / "macos/Sources/KeyfluxApp/Resources/Keyboards/nuphy-air75-v3.json").read_text(encoding="utf-8"))
        self.assertNotEqual(validator.validate(self.layout), validator.validate(other))
        self.assertTrue(other["preview_only"])
        self.assertEqual(len(self.layout["keys"]), 81)
        self.assertTrue(any(k["kind"] == "knob" for k in self.layout["keys"]))
        self.assertTrue(any(k["label"] == "F14" for k in self.layout["keys"]))

    def test_unknown_commands_and_bad_geometry_rejected(self):
        for field, value in [("hid_command", "D6"), ("script", "run()")]:
            bad = copy.deepcopy(self.layout)
            bad[field] = value
            with self.assertRaises(ValueError):
                validator.validate(bad)
        for field, value in [("x", -1), ("w", float("nan")), ("h", 100)]:
            bad = copy.deepcopy(self.layout)
            bad["keys"][0][field] = value
            with self.assertRaises(ValueError):
                validator.validate(bad)
        bad = copy.deepcopy(self.layout)
        bad["keys"][1].update({k: bad["keys"][0][k] for k in ("x", "y", "w", "h")})
        with self.assertRaises(ValueError):
            validator.validate(bad)

    def test_importer_extracts_geometry_and_drops_active_page_content(self):
        fragment = '''<div id="myKeyBoardBac" style="width: 62rem; height: 27rem;">
        <script>do_not_execute()</script><img src="https://untrusted.example/shell.webp">
        <div class="boxBacOut" onclick="do_not_execute()" style="width: 3rem; height: 3rem; left: 2rem; top: 3rem;">
        <div><p class="ellipsis">!</p><p class="ellipsis">1</p></div></div>
        <div class="boxBacOut" style="width: 3rem; height: 3rem; left: 6rem; top: 3rem;">
        <svg><use xlink:href="#search"></use></svg></div></div>'''
        result = importer.extract(fragment, "example-keyboard", "Example")
        validator.validate(result)
        self.assertEqual(result["keys"][0]["label"], "!\n1")
        self.assertEqual(result["keys"][1]["symbol"], "magnifyingglass")
        self.assertEqual(result["keys"][0]["w"], 1)
        self.assertNotIn("do_not_execute", json.dumps(result))
        self.assertNotIn("untrusted.example", json.dumps(result))
        with self.assertRaises(ValueError):
            importer.extract(fragment.replace("#search", "#unknown"), "example-keyboard", "Example")


if __name__ == "__main__":
    unittest.main()
