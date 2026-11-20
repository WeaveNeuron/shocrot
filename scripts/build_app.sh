#!/bin/zsh
# Builds and signs build/Shocrot.app (release, universal).
#
# Usage: scripts/build_app.sh [--adhoc] [--notarize] [--package] [--install]
#   --adhoc     sign ad-hoc and skip every keychain lookup (local checks, CI); same as SHOCROT_SIGN_IDENTITY=-
#   --notarize  notarize and staple (needs a Developer ID identity); implies --package
#   --package   write build/Shocrot-<version>-macOS-universal.{dmg,zip} and their .sha256 for GitHub Releases
#   --install   copy the app to /Applications (quits a running Shocrot first)
#
# Environment: SHOCROT_VERSION (default 1.0.0), SHOCROT_SIGN_IDENTITY, SHOCROT_TEAM_ID, SHOCROT_NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0; NOTARIZE=0; PACKAGE=0; ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --notarize) NOTARIZE=1; PACKAGE=1 ;;
    --package) PACKAGE=1 ;;
    --adhoc) ADHOC=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if (( ADHOC && NOTARIZE )); then
  echo "--adhoc and --notarize can't be combined: notarization needs a Developer ID signature." >&2
  exit 2
fi

VERSION="${SHOCROT_VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Shocrot.app"
LOCALIZATIONS=(en zh-Hans)   # Sources/Shocrot/Resources/<lang>.lproj; en is the development language
ZIP="build/Shocrot-${VERSION}-macOS-universal.zip"
DMG="build/Shocrot-${VERSION}-macOS-universal.dmg"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Shocrot"
ARCHS="$(lipo -archs "$BIN")"
if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
  echo "Expected a universal binary (arm64 + x86_64), got: $ARCHS" >&2
  exit 1
fi

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

# Localizations: copied from the source tree (SwiftPM's own bundle lowercases "zh-Hans.lproj").
for lang in "${LOCALIZATIONS[@]}"; do
  src="Sources/Shocrot/Resources/${lang}.lproj"
  for table in Localizable InfoPlist; do
    if [[ ! -f "$src/$table.strings" ]]; then echo "Missing $src/$table.strings" >&2; exit 1; fi
    plutil -lint -s "$src/$table.strings"
  done
  ditto "$src" "$APP/Contents/Resources/${lang}.lproj"
done
LOCALIZATION_ITEMS="$(printf '<string>%s</string>' "${LOCALIZATIONS[@]}")"

# Default (English) values; <lang>.lproj/InfoPlist.strings localizes them.
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
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATION_ITEMS}</array>
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
  <key>NSScreenCaptureUsageDescription</key><string>Shocrot needs to capture your screen to take screenshots and recognize text.</string>
</dict>
</plist>
EOF
plutil -lint -s "$APP/Contents/Info.plist"

# Signing identity, in order of preference:
#   1. $SHOCROT_SIGN_IDENTITY ("-" or --adhoc: ad-hoc, no keychain access at all)
#   2. Developer ID Application for team $SHOCROT_TEAM_ID (distributable, notarizable)
#   3. "Shocrot Local Signing" self-signed cert (scripts/make_local_cert.sh)
#   4. ad-hoc ("-"), which loses privacy grants on every rebuild
TEAM_ID="${SHOCROT_TEAM_ID:-CQ4STM9Q69}"
IDENTITY="${SHOCROT_SIGN_IDENTITY:-}"
(( ADHOC )) && IDENTITY="-"
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
codesign --verify --strict "$APP"
echo "Signed with: $SIGN"
echo "Built $APP ($VERSION, build $BUILD; $ARCHS; localizations: ${LOCALIZATIONS[*]})"

if (( NOTARIZE )); then
  if [[ "$SIGN" != "Developer ID Application:"* ]]; then
    echo "Notarization needs a Developer ID Application identity (got: $SIGN)." >&2
    exit 1
  fi
  # Credentials come from a notarytool keychain profile, created once with:
  #   xcrun notarytool store-credentials shocrot-notary --apple-id <id> --team-id <team>
  PROFILE="${SHOCROT_NOTARY_PROFILE:-shocrot-notary}"
  UPLOAD="build/Shocrot-${VERSION}-${BUILD}-notarize.zip"
  rm -f "$UPLOAD"
  ditto -c -k --keepParent "$APP" "$UPLOAD"
  xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait
  rm -f "$UPLOAD"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  echo "Notarized and stapled: $APP"
fi

if (( PACKAGE )); then
  # The signature and the stapled ticket live inside the bundle. Local extended attributes (such as
  # com.apple.provenance) are left out so the archive has no __MACOSX/._* entries.
  rm -f "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  (cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  echo "Packaged $ZIP"
  echo "SHA-256:  $(cut -d' ' -f1 "$ZIP.sha256")  (also in $ZIP.sha256)"

  DMG_STAGE="$(mktemp -d)"
  ditto "$APP" "$DMG_STAGE/Shocrot.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  hdiutil create -volname "Shocrot ${VERSION}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$DMG_STAGE"
  if [[ "$SIGN" == "Developer ID Application:"* ]]; then
    codesign --force --timestamp --sign "$SIGN" "$DMG"
  fi
  if (( NOTARIZE )); then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    echo "Notarized and stapled: $DMG"
  fi
  (cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
  echo "Packaged $DMG"
  echo "SHA-256:  $(cut -d' ' -f1 "$DMG.sha256")  (also in $DMG.sha256)"

  if [[ "$SIGN" != "Developer ID Application:"* ]] || (( ! NOTARIZE )); then
    echo "Note: these archives are not notarized; Gatekeeper blocks them on other Macs. Release builds use --notarize." >&2
  fi
fi

if (( INSTALL )); then
  pkill -x Shocrot 2>/dev/null || true
  rm -rf /Applications/Shocrot.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Shocrot.app"
fi
