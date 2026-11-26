#!/bin/zsh
# Installs Minerva as a login service for the current user: the app goes to /Applications and a
# LaunchAgent starts it hidden (--background) at login. Hidden, the Mac does not listen; the phone
# remote, workers and routines keep working. Open the window from the menu bar item, Spotlight or
# Finder to talk to the Mac. "Salir de Minerva" quits until the next login (or `open -a Minerva`).
#
# Usage: tool/install_macos_service.sh [path/to/Minerva.app]   (default: the release build)
#        tool/install_macos_service.sh --uninstall              (removes the LaunchAgent, keeps the app)
set -euo pipefail

label=com.kidandcat.minerva
plist="$HOME/Library/LaunchAgents/$label.plist"
dest=/Applications/Minerva.app
domain="gui/$(id -u)"

stop_service() {
  launchctl bootout "$domain/$label" 2>/dev/null || true
  # A copy started by hand (not by launchd) would keep the new one from starting.
  osascript -e 'if application id "com.kidandcat.minerva" is running then tell application id "com.kidandcat.minerva" to quit' 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -f "$dest/Contents/MacOS/Minerva" >/dev/null || break
    sleep 0.5
  done
}

if [[ "${1:-}" == "--uninstall" ]]; then
  stop_service
  rm -f "$plist"
  echo "LaunchAgent removed; $dest is still installed."
  exit 0
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$repo/build/macos/Build/Products/Release/Minerva.app}"
[[ -d "$src/Contents/MacOS" ]] || { echo "No app at $src (run: flutter build macos --release)" >&2; exit 1; }

# TCC keys Screen Recording and Accessibility on the designated requirement. An ad-hoc signature's
# requirement is its cdhash, so every rebuild lost both grants. Sign with an Apple Development
# identity of the team instead, under a requirement that names the team and not the certificate,
# so it stays the same across builds and across certificate renewals.
team=5M4PZM9Z6T
identity="${MINERVA_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  security find-identity -v -p codesigning | grep '"Apple Development:' | while read -r _ hash name; do
    security find-certificate -c "${${name#\"}%\"}" -p | openssl x509 -noout -subject | grep -qE "OU=$team(,|/|$)" && echo "$hash"
  done | head -1 | read -r identity || true
fi
[[ -n "$identity" ]] || { echo "No Apple Development identity of team $team in the keychain" >&2; exit 1; }
requirement="designated => identifier \"$label\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = \"$team\""

sign() { codesign --force --timestamp=none --options runtime --sign "$identity" "$@"; }

stop_service
rm -rf "$dest"
ditto "$src" "$dest"

# Inside out: nested code first, then the app with its entitlements.
for f in "$dest"/Contents/Frameworks/*(N); do sign "$f"; done
[[ -f "$dest/Contents/MacOS/minerva-webhooks" ]] && sign --identifier "$label.webhooks" "$dest/Contents/MacOS/minerva-webhooks"
sign --entitlements "$repo/macos/Runner/Release.entitlements" -r="$requirement" "$dest"
codesign --verify --deep --strict "$dest"

mkdir -p "$(dirname "$plist")"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dest/Contents/MacOS/Minerva</string>
    <string>--background</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- Restart after a crash, not after "Salir de Minerva". -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/Minerva.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/Minerva.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$domain" "$plist"
echo "Installed $dest and started it in the background (log: ~/Library/Logs/Minerva.log)."
