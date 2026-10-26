#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
    "")
        app="dist/Keyflux.app"
        core_prefix="$PWD/zig-out"
        zig_optimization=ReleaseSafe
        bundle_id=tech.nuclx.keyflux
        bundle_name=Keyflux
        ;;
    --debug)
        app=".build/macos-dev/Keyflux Dev.app"
        core_prefix="$PWD/.build/macos-dev/core"
        zig_optimization=Debug
        bundle_id=tech.nuclx.keyflux.dev
        bundle_name="Keyflux Dev"
        ;;
    --check)
        app=".build/macos-check/Keyflux Check.app"
        core_prefix="$PWD/.build/macos-check/core"
        zig_optimization=Debug
        bundle_id=tech.nuclx.keyflux.check
        bundle_name="Keyflux Check"
        ;;
    --help|-h)
        printf '%s\n' 'Usage: sh scripts/package-macos.sh [--debug|--check]'
        exit 0
        ;;
    *) printf '%s\n' "Unknown option: $1" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { printf '%s\n' 'Too many arguments.' >&2; exit 1; }
zig build -Doptimize="$zig_optimization" --prefix "$core_prefix"
mkdir -p .build/clang-modules
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-modules}"
export CLANG_MODULE_CACHE_PATH
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# The UI has no package dependencies. Compile directly for the development
# bundle; this avoids requiring SwiftPM's build service and dSYM pipeline.
if [ "$zig_optimization" = Debug ]; then
    set -- -Onone -g
else
    set -- -O -whole-module-optimization
fi
swiftc "$@" -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    macos/Sources/KeyfluxApp/*.swift -o "$app/Contents/MacOS/KeyfluxApp"
mkdir -p "$app/Contents/Resources/Keyboards"
cp macos/Sources/KeyfluxApp/Resources/Keyboards/*.json "$app/Contents/Resources/Keyboards/"
cp "$core_prefix/bin/keyflux" "$app/Contents/MacOS/keyflux"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KeyfluxApp</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>$bundle_name</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp vendor/hidapi/LICENSE-bsd.txt "$app/Contents/Resources/HIDAPI-LICENSE.txt"
cp licenses/NuPhyLab-MIT.txt "$app/Contents/Resources/NuPhyLab-MIT.txt"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/MacOS/keyflux"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "Built $app (local development signature; release gates remain unpassed)."
