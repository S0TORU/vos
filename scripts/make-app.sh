#!/bin/zsh
# Build a minimal macOS .app that launches VOS talk in Terminal — Dock-friendly
set -euo pipefail

VOS_REPO="${VOS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT_DIR="$VOS_REPO/dist"
APP="$OUT_DIR/VOS.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VOS</string>
  <key>CFBundleDisplayName</key><string>VOS</string>
  <key>CFBundleIdentifier</key><string>ai.elyris.vos</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>vos-launch</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>VOS listens so you can talk to your personal agent.</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/vos-launch" <<'LAUNCH'
#!/bin/zsh
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
VOS_BIN="${HOME}/bin/vos"
if [[ ! -x "$VOS_BIN" ]]; then
  VOS_BIN="${HOME}/vos/bin/vos"
fi
# Open a Terminal window with recap then talk loop
osascript <<APPLESCRIPT
tell application "Terminal"
  activate
  do script "export PATH=\"\$HOME/bin:/opt/homebrew/bin:\$PATH\"; echo 'VOS'; clear; vos recap; echo; echo 'Starting voice loop (Ctrl+C to stop)…'; vos talk 25"
end tell
APPLESCRIPT
LAUNCH
chmod +x "$APP/Contents/MacOS/vos-launch"

echo "Built: $APP"
echo "Open once: open \"$APP\""
echo "Then right-click Dock icon → Options → Keep in Dock"
echo "First mic use: allow Terminal (or this app) microphone access in System Settings."
