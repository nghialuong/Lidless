#!/bin/bash
# Build the AppIcon.appiconset from a single 1024px master.
# Regenerates icon art then emits all macOS icon sizes + Contents.json.
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="Resources/icon_1024.png"
SET="Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

echo "→ rendering master icon"
swift scripts/make_icon.swift "$MASTER"

emit() { # size filename
  sips -z "$1" "$1" "$MASTER" --out "$SET/$2" >/dev/null
}
echo "→ emitting sizes"
emit 16  icon_16.png
emit 32  icon_32.png
emit 64  icon_64.png
emit 128 icon_128.png
emit 256 icon_256.png
emit 512 icon_512.png
cp "$MASTER" "$SET/icon_1024.png"

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "✓ AppIcon.appiconset ready"
