#!/bin/bash
# Removes Sahba and everything it installed.
#
#   curl -fsSL https://raw.githubusercontent.com/Khxxxxd/sahba/main/uninstall.sh | bash
#
# This file is kept plain ASCII on purpose.
set -euo pipefail

# Testing hook: SAHBA_HOME removes from another folder instead of $HOME (and leaves the running app,
# its login item and its settings alone).
BASE="${SAHBA_HOME:-$HOME}"
APP="$BASE/Applications/Sahba.app"

if [[ -z "${SAHBA_HOME:-}" ]]; then
  # Turn off "Open at Login" before the app is gone, then quit it.
  if [[ -x "$APP/Contents/MacOS/Sahba" ]]; then
    "$APP/Contents/MacOS/Sahba" --unregister-login </dev/null >/dev/null 2>&1 || true
  fi
  pkill -x Sahba 2>/dev/null || true
  for _ in $(seq 50); do pgrep -x Sahba >/dev/null 2>&1 || break; sleep 0.1; done
  defaults delete app.sahba.Sahba >/dev/null 2>&1 || true
  rm -f "$BASE/Library/Logs/Sahba.log"
fi

rm -rf "$APP" "$BASE/Library/Application Support/Sahba"
echo "  Sahba was removed."
