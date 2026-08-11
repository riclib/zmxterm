#!/bin/bash
# Build zmxterm, wrap it in an .app, sign it, and put it in a DMG.
#
# A SwiftPM executable is not an app bundle, so the bundle is assembled by hand
# here rather than by Xcode. That keeps the project a plain `swift build` — no
# .xcodeproj to drift — at the cost of this script owning the Info.plist.
#
#   Scripts/package.sh                 sign with whatever identity is available
#   IDENTITY="Developer ID Application: …" Scripts/package.sh
#   NOTARY_PROFILE=zmxterm Scripts/package.sh    also notarise and staple
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.7.1}"
APP="zmxterm.app"
BUILD="dist"
BUNDLE_ID="land.liberato.zmxterm"

rm -rf "$BUILD"
mkdir -p "$BUILD/$APP/Contents/MacOS" "$BUILD/$APP/Contents/Resources"

echo "── building release"
swift build -c release --disable-sandbox
BIN=$(swift build -c release --show-bin-path)

echo "── assembling $APP"
cp "$BIN/zmxterm" "$BUILD/$APP/Contents/MacOS/zmxterm"
# Bundle.module resolves against the main bundle's resources once the binary
# lives in an .app, so the SwiftPM resource bundle has to come along.
cp -R "$BIN/zmxterm_zmxterm.bundle" "$BUILD/$APP/Contents/Resources/" 2>/dev/null || true

echo "── rendering icon"
ICONSET="$BUILD/zmxterm.iconset"
mkdir -p "$ICONSET"
swiftc -O Scripts/svg2png.swift -o "$BUILD/svg2png"
for size in 16 32 64 128 256 512 1024; do
    "$BUILD/svg2png" Resources-src/appicon/zmxterm.svg "$ICONSET/icon_${size}x${size}.png" "$size"
done
# Retina variants are the same pixels named for half the points.
for size in 16 32 128 256 512; do
    cp "$ICONSET/icon_$((size * 2))x$((size * 2)).png" "$ICONSET/icon_${size}x${size}@2x.png"
done
rm -f "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$BUILD/$APP/Contents/Resources/zmxterm.icns"

cat > "$BUILD/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>zmxterm</string>
    <key>CFBundleDisplayName</key><string>zmxterm</string>
    <key>CFBundleExecutable</key><string>zmxterm</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>zmxterm</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# Prefer a distribution certificate; fall back to a development one, which
# works on this machine and nowhere else.
if [ -z "${IDENTITY:-}" ]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -z "${IDENTITY:-}" ]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
    echo "── no Developer ID found; signing with a development certificate."
    echo "   Gatekeeper will refuse this bundle on any other Mac."
fi

if [ -n "${IDENTITY:-}" ]; then
    echo "── signing as: $IDENTITY"
    # --options runtime is the hardened runtime, which notarisation requires.
    codesign --force --deep --timestamp --options runtime \
        --sign "$IDENTITY" "$BUILD/$APP"
    codesign --verify --strict --verbose=2 "$BUILD/$APP"
else
    echo "── no signing identity at all; leaving the bundle unsigned"
fi

# Notarise the app before the DMG is built, and staple the ticket to the app
# itself. A ticket on only the disk image is enough for Gatekeeper the first
# time, but once someone drags the app to /Applications and the DMG is gone,
# an offline machine has nothing local to check against. Stapling both means
# neither copy ever needs the network.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "── notarising the app"
    ditto -c -k --keepParent "$BUILD/$APP" "$BUILD/zmxterm-app.zip"
    xcrun notarytool submit "$BUILD/zmxterm-app.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUILD/$APP"
    rm -f "$BUILD/zmxterm-app.zip"
fi

echo "── building DMG"
DMG="$BUILD/zmxterm-$VERSION.dmg"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$BUILD/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "zmxterm $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "── notarising the DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vv "$BUILD/$APP"
fi

echo "── done: $DMG"
