#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseSafe
mkdir -p .build/clang-modules
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-modules}"
export CLANG_MODULE_CACHE_PATH
app="dist/Keyflux.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# The UI has no package dependencies. Compile directly for the development
# bundle; this avoids requiring SwiftPM's build service and dSYM pipeline.
swiftc -O -whole-module-optimization -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    macos/Sources/KeyfluxApp/main.swift -o "$app/Contents/MacOS/KeyfluxApp"
cp zig-out/bin/keyflux "$app/Contents/MacOS/keyflux"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KeyfluxApp</string>
<key>CFBundleIdentifier</key><string>tech.nuclx.keyflux</string>
<key>CFBundleName</key><string>Keyflux</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp vendor/hidapi/LICENSE-bsd.txt "$app/Contents/Resources/HIDAPI-LICENSE.txt"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/MacOS/keyflux"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "Built $app (local development signature, hardware gates remain locked)."
