#!/usr/bin/env bash
# Build crier-ui as a real .app bundle so macOS treats it as a first-class
# app for Accessibility (and any future TCC-gated permissions). Without this,
# the binary has no bundle identity and either doesn't appear in the
# Accessibility list at all, or appears by raw filename and behaves oddly.
#
# Ad-hoc code-sign at the end pins the bundle's identity to its binary
# content — Accessibility grants stick across rebuilds *if the binary doesn't
# change*. Any code change shifts the signature hash and you'll need to
# re-grant. Real persistence requires a Developer ID signature; out of scope.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Output at repo root (not under .build/) so the .app is visible in Finder
# and can be dragged into Accessibility / Applications without showing
# hidden files.
APP="$REPO_DIR/Crier.app"

command -v swift    >/dev/null || { echo "Swift toolchain required" >&2; exit 1; }
command -v codesign >/dev/null || { echo "codesign required (Xcode CLT)" >&2; exit 1; }

echo "==> Building crier-ui (release)"
( cd "$REPO_DIR" && swift build -c release --product crier-ui )

BIN="$REPO_DIR/.build/release/crier-ui"
test -x "$BIN" || { echo "build did not produce $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Crier"

# Generate AppIcon.icns from the SF Symbol "megaphone.fill" on a brand-orange
# tile. make-icon.swift renders a Crier.iconset of PNGs at the required
# sizes; iconutil packages it into the .icns macOS expects.
ICONSET="$REPO_DIR/.build/Crier.iconset"
echo "==> Rendering AppIcon"
swift "$REPO_DIR/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Brand icons from @lobehub/lobe-icons (vendored as SVGs in assets/icons).
if [ -d "$REPO_DIR/assets/icons" ]; then
    cp "$REPO_DIR"/assets/icons/*.svg "$APP/Contents/Resources/" 2>/dev/null || true
    echo "==> Copied $(/bin/ls "$REPO_DIR"/assets/icons/*.svg 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') brand icons"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>          <string>com.crier.ui</string>
  <key>CFBundleName</key>                <string>Crier</string>
  <key>CFBundleDisplayName</key>         <string>Crier</string>
  <key>CFBundleExecutable</key>          <string>Crier</string>
  <key>CFBundleIconFile</key>            <string>AppIcon</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>CFBundleVersion</key>             <string>0.0.1</string>
  <key>CFBundleShortVersionString</key>  <string>0.0.1</string>
  <key>LSMinimumSystemVersion</key>      <string>14.0</string>
  <key>LSUIElement</key>                 <true/>
  <key>NSHumanReadableCopyright</key>    <string>Crier — local agent overlay</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo
echo "Built: $APP"
echo
echo "Launch:    open '$APP'"
echo "Reveal:    open -R '$APP'   (opens Finder selecting Crier.app, ready to drag)"
echo
echo "First launch shows an alert if Accessibility isn't granted."
echo "Normally the entry auto-appears in Settings → Accessibility (just toggle it on)."
echo "If it doesn't, drag Crier.app from this folder into the Accessibility list."
