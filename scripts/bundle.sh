#!/bin/zsh
# Builds Edo.app and installs it in ~/Applications, so macOS can grant it microphone and
# screen-recording access and Spotlight finds it.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

config=${1:-release}
root=${0:A:h:h}
cd "$root"

swift build -c "$config" --product edo
bin=$(swift build -c "$config" --show-bin-path)

app="$root/.build/Edo.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/edo" "$app/Contents/MacOS/edo"

# The icon is rendered from assets/AppIcon.svg, and again only when the SVG changes.
icon="$root/.build/AppIcon.icns"
if [[ ! -f "$icon" || "$root/assets/AppIcon.svg" -nt "$icon" ]]; then
    if ! command -v rsvg-convert >/dev/null; then
        echo "Edo needs rsvg-convert to draw its icon: brew install librsvg" >&2
        exit 1
    fi
    iconset=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$iconset"
    for px in 16 32 128 256 512; do
        rsvg-convert -w $px -h $px "$root/assets/AppIcon.svg" -o "$iconset/icon_${px}x${px}.png"
        rsvg-convert -w $((px * 2)) -h $((px * 2)) "$root/assets/AppIcon.svg" -o "$iconset/icon_${px}x${px}@2x.png"
    done
    iconutil -c icns "$iconset" -o "$icon"
fi
mkdir -p "$app/Contents/Resources"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.edo.Edo</string>
    <key>CFBundleName</key>
    <string>Edo</string>
    <key>CFBundleDisplayName</key>
    <string>Edo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>edo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Edo records your voice-over while it records the screen.</string>
</dict>
</plist>
PLIST

# A stable identity keeps the microphone and screen-recording permission across rebuilds.
identity="Edo Local Signing"
if ! security find-identity -p codesigning | grep -q "\"$identity\""; then
    echo "No \"$identity\" certificate, so macOS will ask for permissions again after each build." >&2
    echo "Run scripts/make-signing-cert.sh once to fix that." >&2
    identity=-
fi
codesign --force --sign "$identity" "$app"

# The installed copy is the one to open: Spotlight and the Dock find it, and each build replaces it.
installed="$HOME/Applications/Edo.app"
mkdir -p "$HOME/Applications"
rm -rf "$installed"
ditto "$app" "$installed"
echo "$installed"
