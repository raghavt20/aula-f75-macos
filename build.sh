#!/bin/zsh
# Builds "F75 Music.app" next to this script.
set -e
cd "$(dirname "$0")"
APP="F75 Music.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
    Core.swift Effects.swift App.swift -o "$APP/Contents/MacOS/F75Music"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>F75 Music</string>
    <key>CFBundleDisplayName</key><string>F75 Music</string>
    <key>CFBundleIdentifier</key><string>local.f75music</string>
    <key>CFBundleExecutable</key><string>F75Music</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign "${SIGN_ID:-TabDisplay Signing}" --identifier local.f75music "$APP"
echo "Built $PWD/$APP"
