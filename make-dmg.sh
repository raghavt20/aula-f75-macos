#!/bin/zsh
# Builds the app and packages it as dist/F75-Music-<version>.dmg.
set -e
cd "$(dirname "$0")"
VERSION="1.0"
./build.sh
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "F75 Music.app" "$STAGE/F75 Music.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "dist/F75-Music-$VERSION.dmg"
hdiutil create -quiet -volname "F75 Music $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/F75-Music-$VERSION.dmg"
echo "Built $PWD/dist/F75-Music-$VERSION.dmg"
