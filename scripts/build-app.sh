#!/bin/zsh
# Builds C2026.app (release) without Xcode: compiles with SwiftPM, assembles the bundle, signs.
#
#   scripts/build-app.sh                         # Apple Silicon, ad-hoc signed (runs on this Mac)
#   scripts/build-app.sh --universal             # Apple Silicon + Intel
#   scripts/build-app.sh --release               # universal + Developer ID + notarized → build/C2026-<version>.zip
#
# --release needs (once per Mac):
#   • a "Developer ID Application" certificate in the login keychain
#     (security find-identity -v -p codesigning should list it), and
#   • notarization credentials stored under the profile name "C2026":
#       xcrun notarytool store-credentials C2026 --apple-id <your Apple ID> --team-id <TEAM ID>
#     (it asks for an app-specific password from appleid.apple.com; it's kept in the keychain).
# Override with --sign "<identity>" and --notary-profile <name>.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.0.0"
OUT="build/C2026.app"
ARCHS=(arm64)
IDENTITY="-"          # ad-hoc
NOTARY_PROFILE=""

while (( $# )); do
  case "$1" in
    --universal) ARCHS=(arm64 x86_64) ;;
    --release)   ARCHS=(arm64 x86_64); IDENTITY="auto"; NOTARY_PROFILE="C2026" ;;
    --sign)      IDENTITY="$2"; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$IDENTITY" == "auto" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate in the keychain." >&2; exit 1; }
fi

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
  <key>CFBundleIdentifier</key><string>com.lessavyfav.c2026</string>
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

# Hardened runtime is required for notarization; C2026 needs no extra entitlements
# (CoreMIDI and audio playback work under it).
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - "$OUT"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT"
fi
codesign --verify --strict "$OUT"
echo "Built $OUT (${ARCHS[*]}), signed by: ${IDENTITY/#-/ad-hoc}"

if [[ -n "$NOTARY_PROFILE" ]]; then
  ZIP="build/C2026-${VERSION}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$OUT" "$ZIP"
  echo "Submitting to Apple for notarization (usually a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$OUT" "$ZIP"   # re-zip with the notarization ticket stapled in
  spctl --assess --type execute --verbose=2 "$OUT"
  echo "Ready to share: $ZIP"
fi
