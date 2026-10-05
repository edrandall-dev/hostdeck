#!/bin/zsh
# Build HostDeck.app and install it in ~/Applications.
# Usage: ./build.sh [--no-install]

set -euo pipefail
cd "${0:A:h}"

APP=build/HostDeck.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -parse-as-library -swift-version 5 -O \
    -target "$(uname -m)-apple-macos14.0" \
    Sources/HostDeck.swift -o "$APP/Contents/MacOS/HostDeck"

cp Resources/Info.plist "$APP/Contents/Info.plist"

swift Tools/make-icon.swift build/icon.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
    rm -rf ~/Applications/HostDeck.app
    cp -R "$APP" ~/Applications/
    echo "Installed ~/Applications/HostDeck.app"
fi
