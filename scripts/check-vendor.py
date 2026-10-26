"""Verify vendored HIDAPI files against their pinned upstream Git blob IDs."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "vendor/hidapi"
manifest = json.loads((root / "UPSTREAM.json").read_text())
for entry in manifest["files"]:
    data = (root / entry["path"]).read_bytes()
    actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if actual != entry["git_blob_sha"]:
        raise SystemExit("Vendored file differs from upstream: " + entry["path"])
print(f"{len(manifest['files'])} HIDAPI files match pinned upstream blobs")
