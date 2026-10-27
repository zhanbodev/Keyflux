#!/bin/sh
# Explicit manual hardware check; never invoked by CI.
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--no-build" ]; then
  zig build -Doptimize=ReleaseSafe
fi
binary=./zig-out/bin/keyflux
snapshot=$("$binary" hardware-status)
printf '%s' "$snapshot" | python3 -c '
import json,sys
s=json.load(sys.stdin)
if not s.get("probe"): raise SystemExit("Connect the original USB Kick75 in Mac mode.")
if s["recovery"]["required"]: raise SystemExit("Existing capture: quit Keyflux and run hardware-restore on the original device before this test.")
'
restore() { "$binary" hardware-restore; }
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
for effect in marquee orbit blink; do
  printf 'Observe %s for four seconds; the strip must stay unchanged.\n' "$effect"
  printf '{"color":"#06B6D4","brightness":15,"effect":"%s","speed":2}' "$effect" | "$binary" hardware-effect
  sleep 4
done
restore
trap - EXIT
printf 'Configuration readback and restoration passed. Physical appearance requires your observation.\n'
