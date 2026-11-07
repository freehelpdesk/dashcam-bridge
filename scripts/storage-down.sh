#!/bin/bash
# Unmount the snapshot and drop the device-mapper devices. Shutdown only.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root
[[ -f /etc/dashcam-bridge.env ]] || exit 0
load_env
lock_wait

"$(dirname "${BASH_SOURCE[0]}")/gadget-down.sh" || true

if ! release_dashcam_devices; then
  echo "dashcam storage is still busy" >&2
  exit 1
fi
exit 0
