#!/bin/bash
# Mount the frozen SMB view and the inbox, once the USB drive is up for the car.
# Nothing here can stop the boot. Samba refuses a share until its mount exists.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

share_up() {
  # Live mode already mounted the drive, before the car could write to it.
  [[ $SHARE == snapshot ]] || return 0
  lock_wait
  origin_exists || return 0
  storage_try "the share is not mounted. The USB drive is still up for the car." mount_share
  storage_try "the inbox is not available. The USB drive is still up for the car." inbox_up
}

# Sourced by the tests. A normal run is not sourced, so `return` fails and we continue.
if [[ ${DASHCAM_TEST:-} == 1 ]]; then
  return 0 2>/dev/null || true
fi

require_root
load_env
share_up
