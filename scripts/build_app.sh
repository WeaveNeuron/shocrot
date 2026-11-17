#!/bin/zsh
# Builds and signs build/Shocrot.app (release). Usage: scripts/build_app.sh [--install] [--notarize]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${SHOCROT_VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Shocrot.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Shocrot"

# App icon (regenerated only when missing)
if [[ ! -f Resources/AppIcon.icns ]]; then
  tmp="$(mktemp -d)"
  swift scripts/make_icon.swift "$tmp/icon.png"
  mkdir -p "$tmp/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shocrot"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Shocrot</string>
  <key>CFBundleDisplayName</key><string>Shocrot</string>
  <key>CFBundleIdentifier</key><string>com.weaveneuron.shocrot</string>
  <key>CFBundleExecutable</key><string>Shocrot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 WeaveNeuron</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.weaveneuron.shocrot</string>
    <key>CFBundleURLSchemes</key><array><string>shocrot</string></array>
  </dict></array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSScreenCaptureUsageDescription</key><string>Shocrot 需要截取屏幕内容来完成截图和文字识别。</string>
</dict>
</plist>
EOF

# Signing identity, in order of preference:
#   1. $SHOCROT_SIGN_IDENTITY
#   2. Developer ID Application for team $SHOCROT_TEAM_ID (distributable, notarizable)
#   3. "Shocrot Local Signing" self-signed cert (scripts/make_local_cert.sh)
#   4. ad-hoc ("-"), which loses privacy grants on every rebuild
TEAM_ID="${SHOCROT_TEAM_ID:-CQ4STM9Q69}"
IDENTITY="${SHOCROT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/.*\"\(Developer ID Application: .* (${TEAM_ID})\)\".*/\1/p" | head -1)"
fi
if [[ -z "$IDENTITY" ]] && security find-certificate -c "Shocrot Local Signing" >/dev/null 2>&1; then
  IDENTITY="Shocrot Local Signing"
fi
SIGN="${IDENTITY:--}"
# A locked login keychain makes codesign wait for a password (or fail); stop early instead.
if [[ "$SIGN" != "-" ]] && ! security show-keychain-info login.keychain >/dev/null 2>&1; then
  echo "The login keychain is locked (screen locked?). Unlock the Mac and build again." >&2
  exit 1
fi
if [[ "$SIGN" == "Developer ID Application:"* ]]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN" --identifier com.weaveneuron.shocrot "$APP"
else
  codesign --force --deep --sign "$SIGN" --identifier com.weaveneuron.shocrot "$APP"
fi
echo "Signed with: $SIGN"
echo "Built $APP"

INSTALL=0; NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( NOTARIZE )); then
  if [[ "$SIGN" != "Developer ID Application:"* ]]; then
    echo "Notarization needs a Developer ID Application identity (got: $SIGN)." >&2
    exit 1
  fi
  # Credentials come from a notarytool keychain profile, created once with:
  #   xcrun notarytool store-credentials shocrot-notary --apple-id <id> --team-id <team>
  PROFILE="${SHOCROT_NOTARY_PROFILE:-shocrot-notary}"
  ZIP="build/Shocrot-${VERSION}-${BUILD}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
  echo "Notarized and stapled: $APP (zip: $ZIP)"
fi

if (( INSTALL )); then
  pkill -x Shocrot 2>/dev/null || true
  rm -rf /Applications/Shocrot.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Shocrot.app"
fi
