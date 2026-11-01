#!/bin/zsh
# Builds "F75 Music.app" next to this script.
#   ./build.sh                            universal app, ad-hoc signed
#   SIGN_ID="My Cert" ./build.sh          sign with a local certificate, so macOS keeps
#                                         privacy permissions across rebuilds
set -e
cd "$(dirname "$0")"
APP="F75 Music.app"
VERSION="1.0"
SOURCES=(Core.swift Effects.swift App.swift)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos13.0" "${SOURCES[@]}" -o "$TMP/F75Music-$arch"
done
lipo -create "$TMP/F75Music-arm64" "$TMP/F75Music-x86_64" -output "$APP/Contents/MacOS/F75Music"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>F75 Music</string>
    <key>CFBundleDisplayName</key><string>F75 Music</string>
    <key>CFBundleIdentifier</key><string>local.f75music</string>
    <key>CFBundleExecutable</key><string>F75Music</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_ID:--}" --identifier local.f75music "$APP"
echo "Built $PWD/$APP"
