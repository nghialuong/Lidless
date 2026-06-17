#!/bin/bash
# Lidless — M0 spike
# Keep a MacBook (Apple Silicon) running EVEN WITH THE LID CLOSED so coding
# agents keep working. Mechanism: set the SleepDisabled flag in IOPMrootDomain
# via `pmset -a disablesleep`. This shell version is the spike; the real app
# calls the API directly through a root helper.
#
# USAGE (run on the MacBook, not the Mac mini — the mini has no lid):
#   chmod +x lidless.sh
#   ./lidless.sh on        # keep running with lid closed
#   ./lidless.sh off       # restore normal sleep (RUN THIS WHEN DONE!)
#   ./lidless.sh status
#   ./lidless.sh toggle
#
# SAFETY: needs sudo. While ON with the lid closed on battery the machine gets
# HOT and drains fast — keep it plugged in and ventilated. Reboot resets it.

set -euo pipefail

get_state() {
  if pmset -g 2>/dev/null | grep -qiE 'SleepDisabled[[:space:]]+1'; then
    echo "on"
  else
    echo "off"
  fi
}

batt() { pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1 || echo "?"; }
power_source() { pmset -g batt 2>/dev/null | grep -qi "AC Power" && echo "AC" || echo "Battery"; }

show_status() {
  local s; s=$(get_state)
  if [ "$s" = "on" ]; then
    echo "🟢 Lidless ON — running with lid closed."
  else
    echo "⚪️ Lidless OFF — normal sleep on lid close."
  fi
  echo "   Source: $(power_source) | Battery: $(batt)"
}

turn_on() {
  echo "→ Enabling Lidless (sudo)..."
  sudo pmset -a disablesleep 1
  sleep 1
  if [ "$(get_state)" = "on" ]; then
    echo "✅ ON. Close the lid — the machine should stay up."
    echo "⚠️  Remember to run: ./lidless.sh off"
  else
    echo "❌ Could not set the flag."
    echo "   $(pmset -g | grep -i sleepdisabled || echo 'no SleepDisabled line')"
    exit 1
  fi
}

turn_off() {
  echo "→ Disabling Lidless (sudo)..."
  sudo pmset -a disablesleep 0
  sleep 1
  if [ "$(get_state)" = "off" ]; then
    echo "✅ OFF. Normal sleep restored."
  else
    echo "❌ Still on? Try again or reboot to reset."
    exit 1
  fi
}

cmd="${1:-status}"
case "$cmd" in
  on)      turn_on ;;
  off)     turn_off ;;
  status)  show_status ;;
  toggle)  [ "$(get_state)" = "on" ] && turn_off || turn_on ;;
  *) echo "Usage: $0 {on|off|status|toggle}"; exit 2 ;;
esac
