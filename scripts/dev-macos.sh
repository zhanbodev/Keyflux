#!/bin/sh
# Shared React settings app, supervised simulated Zig core; no installation.
set -eu
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'This launcher requires macOS.' >&2; exit 1; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec node "$root/desktop/scripts/dev.mjs" "$@"
