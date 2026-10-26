#!/bin/sh
# Manual hardware validation. Never connects agent events to physical lighting.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
core="$root/zig-out/bin/keyflux"
case "${1-}" in
    --help|-h)
        printf '%s\n' 'Usage: ./scripts/test-kick75-macos.sh [--no-build]' \
          'Tests red, cyan and purple at 15% brightness, then restores the captured main effect.' \
          'Watch the physical keyboard: configuration readback alone cannot prove its appearance.' \
          'Requires USB Kick75 IO 4.0.18.6 in Mac profile. Close other lighting clients first.'
        exit 0 ;;
    --no-build|'') ;;
    *) printf '%s\n' 'Unknown argument. Use --help.' >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'macOS required.' >&2; exit 1; }
cd "$root"
if [ "${1-}" != --no-build ]; then
    zig build -Doptimize=ReleaseSafe
fi
"$core" hardware-probe
restore=0
cleanup() {
    result=$?
    trap - EXIT INT TERM HUP
    if [ "$restore" -eq 1 ]; then
        if ! "$core" hardware-restore; then
            printf '%s\n' 'Recovery remains pending. Reconnect the same USB port, select Mac profile, and run:' \
              "  '$core' hardware-restore" >&2
            exit 1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# Set before starting the subprocess: an interrupted write may already be applied.
restore=1
for color in '#FF0000' '#00FFFF' '#8000FF'; do
    printf '%s\n' "Main light: $color at 15% (3 seconds)."
    "$core" hardware-solid "$color" 15
    sleep 3
done
# Exercise the inverse encoder on the purple state while the original-state
# journal remains durable. It must come back byte-for-byte, without RGB drift.
"$core" hardware-verify-restore
