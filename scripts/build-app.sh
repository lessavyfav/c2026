#!/bin/zsh
# Builds C2026.app (release) without Xcode: compiles with SwiftPM, assembles the bundle, ad-hoc signs.
#   scripts/build-app.sh            # Apple Silicon only
#   scripts/build-app.sh --universal  # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.0.0"
OUT="build/C2026.app"
ARCHS=(arm64)
[[ "${1:-}" == "--universal" ]] && ARCHS=(arm64 x86_64)

bins=()
for arch in $ARCHS; do
  swift build -c release --arch "$arch" --product C2026App
  bins+=(".build/${arch}-apple-macosx/release/C2026App")
done

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
if (( ${#bins} > 1 )); then lipo -create $bins -output "$OUT/Contents/MacOS/C2026"; else cp "${bins[1]}" "$OUT/Contents/MacOS/C2026"; fi
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>C2026</string>
  <key>CFBundleDisplayName</key><string>C2026</string>
  <key>CFBundleExecutable</key><string>C2026</string>
  <key>CFBundleIdentifier</key><string>local.c2026</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SysEx file</string>
      <key>CFBundleTypeExtensions</key><array><string>syx</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>C6 file list</string>
      <key>CFBundleTypeExtensions</key><array><string>c6</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$OUT"
echo "Built $OUT (${ARCHS[*]})"
