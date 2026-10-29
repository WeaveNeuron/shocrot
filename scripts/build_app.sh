#!/bin/zsh
# Builds build/Shocrot.app (release, ad-hoc signed). Usage: scripts/build_app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
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
  <key>CFBundleVersion</key><string>1</string>
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

codesign --force --deep --sign - --identifier com.weaveneuron.shocrot "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Shocrot 2>/dev/null || true
  rm -rf /Applications/Shocrot.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Shocrot.app"
fi
