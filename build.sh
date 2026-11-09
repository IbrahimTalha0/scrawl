#!/usr/bin/env bash
# Builds Scrawl.app (universal: Apple Silicon + Intel) without Xcode projects.
#   ./build.sh            build into ./build/Scrawl.app
#   ./build.sh install    build and copy to /Applications
#   ./build.sh zip        build and create ./build/Scrawl.zip for a release
#   ARCHS=arm64 ./build.sh    build for Apple Silicon only (faster)
set -euo pipefail
cd "$(dirname "$0")"

APP=Scrawl
VERSION=1.0.0
BUILD_NUMBER=1
OUT=build
APPDIR="$OUT/$APP.app"
ARCHS="${ARCHS:-arm64 x86_64}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

bins=()
for arch in $ARCHS; do
    echo "→ Compiling for $arch"
    xcrun swiftc \
        -O -wmo -swift-version 5 \
        -target "$arch-apple-macos12.0" \
        -sdk "$SDK" \
        -Xlinker -dead_strip \
        Sources/*.swift \
        -o "$OUT/$APP-$arch"
    bins+=("$OUT/$APP-$arch")
done

lipo -create "${bins[@]}" -output "$APPDIR/Contents/MacOS/$APP"
strip -x "$APPDIR/Contents/MacOS/$APP"
rm -f "${bins[@]}"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APPDIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APPDIR/Contents/Resources/"

# Ad-hoc signature (required to run on Apple Silicon).
codesign --force --sign - "$APPDIR" >/dev/null
echo "✓ Built $APPDIR ($(du -sh "$APPDIR" | cut -f1))"

case "${1:-}" in
    install)
        pkill -x "$APP" 2>/dev/null || true
        rm -rf "/Applications/$APP.app"
        cp -R "$APPDIR" /Applications/
        echo "✓ Installed to /Applications/$APP.app"
        open "/Applications/$APP.app"
        ;;
    zip)
        rm -f "$OUT/$APP.zip"
        ditto -c -k --keepParent "$APPDIR" "$OUT/$APP.zip"
        echo "✓ $OUT/$APP.zip"
        ;;
esac
