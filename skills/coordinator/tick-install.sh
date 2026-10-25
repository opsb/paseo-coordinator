#!/usr/bin/env bash
# Installs the launchd job that runs tick.sh every minute, or removes it with --uninstall.
# tick.sh keeps to working hours itself. Any COORD_* variables set when installing are passed to
# every tick, which is how a test install points at a test state directory.
#
# Usage: tick-install.sh [--uninstall]

set -euo pipefail

label="com.$(id -un).coordinator-tick"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
skill_dir=$(cd "$(dirname "$0")" && pwd)
state_root=${COORD_STATE_ROOT:-$HOME/.local/state/coordinator}

# launchd's /bin/bash is 3.2; prefer a current bash when there is one.
bash_path() {
  local candidate
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    [[ -x $candidate ]] && { echo "$candidate"; return; }
  done
}

environment_entries() {
  env | grep '^COORD_' | sort | while IFS='=' read -r key value; do
    printf '    <key>%s</key><string>%s</string>\n' "$key" "$value"
  done
}

write_plist() {
  mkdir -p "$state_root" "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$(bash_path)</string><string>$skill_dir/tick.sh</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$state_root/launchd.log</string>
  <key>StandardErrorPath</key><string>$state_root/launchd.log</string>
  <key>EnvironmentVariables</key>
  <dict>
$(environment_entries)
  </dict>
</dict>
</plist>
EOF
}

unload() {
  launchctl bootout "$domain/$label" 2> /dev/null || true
}

case ${1:-} in
  --uninstall)
    unload
    rm -f "$plist"
    echo "Removed $label."
    ;;
  "")
    unload
    write_plist
    launchctl bootstrap "$domain" "$plist"
    echo "Installed $label: runs $skill_dir/tick.sh every minute, 08:00 to 22:00 London time."
    echo "Log: $state_root/tick.log"
    ;;
  *)
    echo "usage: tick-install.sh [--uninstall]" >&2
    exit 2
    ;;
esac
