#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Expected a numeric major.minor.patch version.\n' >&2
    exit 1
fi
mkdir -p "$ROOT/build" "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/build/package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PACKAGE="$WORK/God of War Depth Fix"
APP="$PACKAGE/God of War Depth Fix.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PACKAGE/Manual install"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -target "$ARCH-apple-macos13.0" \
        "$ROOT/installer.swift" -o "$WORK/installer-$ARCH" \
        -framework AppKit -framework CryptoKit
done
xcrun lipo -create "$WORK/installer-arm64" "$WORK/installer-x86_64" \
    -output "$APP/Contents/MacOS/God of War Depth Fix"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>God of War Depth Fix</string>
<key>CFBundleIdentifier</key><string>io.github.todaymare.gow-crossover-depth-fix</string>
<key>CFBundleName</key><string>God of War Depth Fix</string>
<key>CFBundleDisplayName</key><string>God of War Depth Fix</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp "$ROOT/d3d11.dll" "$ROOT/gow_proxy_depth.txt" "$APP/Contents/Resources/"
cp "$ROOT/d3d11.dll" "$ROOT/gow_proxy_depth.txt" "$PACKAGE/Manual install/"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$PACKAGE/"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/ditto -c -k --keepParent "$PACKAGE" "$ROOT/dist/gow-crossover-depth-fix-macos.zip"
(cd "$ROOT/dist" && /usr/bin/shasum -a 256 gow-crossover-depth-fix-macos.zip > SHA256SUMS.txt)
printf 'Release archive: %s\n' "$ROOT/dist/gow-crossover-depth-fix-macos.zip"
