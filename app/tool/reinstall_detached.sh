#!/bin/zsh
# Reinstall Minerva from a process detached from Minerva itself, so killing the old app
# doesn't kill the install, and make sure the new app is running at the end.
# Usage: tool/reinstall_detached.sh   (returns at once; log: /tmp/minerva-install.log)
dir=${0:A:h}
log=/tmp/minerva-install.log
if [[ "$1" != "--child" ]]; then
  # Its own launchd job: bootout of Minerva's job kills every process in that job, nohup or not.
  # In the gui domain so the login keychain (signing identity) is reachable.
  plist=/tmp/com.kidandcat.minerva.reinstall.plist
  cat > "$plist" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.kidandcat.minerva.reinstall</string>
<key>ProgramArguments</key><array><string>$0</string><string>--child</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$log</string>
<key>StandardErrorPath</key><string>$log</string>
</dict></plist>
EOP
  launchctl bootout gui/$UID/com.kidandcat.minerva.reinstall 2>/dev/null
  launchctl bootstrap gui/$UID "$plist"
  echo "reinstall started in background (log: $log)"
  exit 0
fi
sleep 3
echo "== $(date) installing"
"$dir/install_macos_service.sh"
rc=$?
echo "== install exit $rc"
sleep 5
if ! pgrep -xq Minerva; then
  echo "== Minerva not running, opening it"
  open -a /Applications/Minerva.app
fi
echo "== $(date) done"
launchctl bootout gui/$UID/com.kidandcat.minerva.reinstall
