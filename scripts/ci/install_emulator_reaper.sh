#!/usr/bin/env bash
# Installs (or removes) a launchd job that stops orphaned Firebase emulators
# every 5 minutes: Java emulator processes whose launcher is gone (a shell
# killed by a tool timeout, a closed terminal), which otherwise keep their
# ports and 1-3 GB of memory until someone kills them. See
# scripts/ci/emulator_orphans.js for what counts as an orphan; the shared
# rules-test emulator is never touched while its supervisor is alive.
#
# The job runs a copy of emulator_orphans.js from
# ~/.cache/bluejay-rules-tests/reaper/, so it keeps working whatever happens
# to this checkout; run this script again to pick up a newer copy.
#
# Usage: scripts/ci/install_emulator_reaper.sh [--uninstall]
# Log:   ~/.cache/bluejay-rules-tests/reaper/reaper.log
set -euo pipefail

LABEL=com.bluejay.emulator-reaper
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$HOME/.cache/bluejay-rules-tests/reaper"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/emulator_orphans.js"

if [ "$(uname)" != Darwin ]; then
  echo "launchd is macOS only; on Linux run 'node $SRC reap' from cron instead." >&2
  exit 1
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = --uninstall ]; then
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

NODE="$(command -v node)"
[ -n "$NODE" ] || { echo "node isn't on PATH" >&2; exit 1; }
mkdir -p "$DIR" "$(dirname "$PLIST")"
cp "$SRC" "$DIR/emulator_orphans.js"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Installed by scripts/ci/install_emulator_reaper.sh; remove with --uninstall. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$DIR/emulator_orphans.js</string>
    <string>reap</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$DIR/reaper.log</string>
  <key>StandardErrorPath</key>
  <string>$DIR/reaper.log</string>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL: reaps orphaned emulators every 5 minutes (log: $DIR/reaper.log)."
