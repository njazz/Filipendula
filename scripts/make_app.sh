#!/bin/bash
# Builds build/Filipendula.app (universal, with icon) and optionally signs, zips, makes a DMG and notarizes it.
#
#   ./scripts/make_app.sh                         # ad-hoc signed app, runs on this Mac
#   VERSION=1.2.0 ./scripts/make_app.sh           # set the version shown in Finder
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./scripts/make_app.sh
#   SIGN_ID=... NOTARY_PROFILE=filipendula ./scripts/make_app.sh    # also notarize + staple
#
# One-time notary setup:
#   xcrun notarytool store-credentials filipendula --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Filipendula"
BUNDLE_ID="${BUNDLE_ID:-dev.filipendula.app}"
VERSION="${VERSION:-$(./scripts/version.sh)}"   # from Sources/MergeCore/Version.swift
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_ID="${SIGN_ID:--}"                       # "-" = ad-hoc
ARCHS="${ARCHS:-arm64 x86_64}"                # universal by default
CONFIG="${CONFIG:-release}"                   # release | debug
QUICK="${QUICK:-0}"                           # 1 = skip zip/notarize (used by run.sh)
APP="build/$NAME.app"

echo "==> Building $CONFIG ($ARCHS)..."
ARCH_FLAGS=""
for a in $ARCHS; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done
swift build -c "$CONFIG" --product FilipendulaApp $ARCH_FLAGS
BIN="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)/FilipendulaApp"
[ -f "$BIN" ] || { echo "Built binary not found at $BIN"; exit 1; }

echo "==> Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

echo "==> Building icon..."
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
SRC="Resources/AppIcon.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright $(date +%Y) ${NAME}</string>
</dict>
</plist>
PLIST

echo "==> Signing ($SIGN_ID)..."
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --deep --sign - "$APP"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "  signature OK"

if [ "$QUICK" = "1" ]; then echo "Built $APP"; exit 0; fi

ZIP="build/$NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_ID" != "-" ]; then
    echo "==> Notarizing (this takes a few minutes)..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
fi

echo
echo "Done:"
echo "  $APP"
echo "  $ZIP   (share this)"
echo "Check it is a real bundle:  file \"$APP/Contents/MacOS/$NAME\"  &&  open \"$APP\""
echo "Install: drag $APP into /Applications."
echo "Optional CLI: swift build -c release --product filipendula && cp .build/release/filipendula /usr/local/bin/"
