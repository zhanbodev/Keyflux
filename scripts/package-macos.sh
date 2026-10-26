#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'This packager requires macOS.' >&2; exit 1; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
case "${1:-}" in
  "") exec npm --prefix "$root/desktop" run build -- --bundles app ;;
  --debug) exec npm --prefix "$root/desktop" run build -- --debug --bundles app ;;
  --check) exec node "$root/desktop/scripts/dev.mjs" --check ;;
  --help|-h) printf '%s\n' 'Usage: sh scripts/package-macos.sh [--debug|--check]' ;;
  *) printf '%s\n' "Unknown option: $1" >&2; exit 1 ;;
esac
