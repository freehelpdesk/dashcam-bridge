#!/bin/bash
# Replace the frozen snapshot the share is reading, once nothing is copying.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root
load_env
lock_nowait || exit 0
origin_exists || exit 0

if [[ $SHARE == live ]]; then
  live_refresh
  exit 0
fi

stamp=$STATE_DIR/refresh-stamp
if [[ -f $stamp ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 55 )); then
  exit 0
fi

if smb_busy; then
  if pct=$(cow_percent); then
    if ((pct >= 70)); then
      warn "snapshot scratch is ${pct}% full while a client is connected"
    fi
  fi
  exit 0
fi

refresh_snapshot
touch "$stamp"
