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

set +e
if findmnt -n --mountpoint "$MNT" >/dev/null; then
  sync
  umount "$MNT"
fi
kpartx -d /dev/mapper/dashcam-snap >/dev/null 2>&1
if dmsetup info dashcam-origin >/dev/null 2>&1; then
  dmsetup suspend dashcam-origin
  dmsetup remove dashcam-snap
  dmsetup resume dashcam-origin
  dmsetup remove dashcam-origin
fi
dmsetup remove dashcam-snap >/dev/null 2>&1
if [[ -f $STATE_DIR/loops ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/loops"
  [[ ${ORIGIN_LOOP:-} == /dev/loop* ]] && losetup -d "$ORIGIN_LOOP"
  [[ ${COW_LOOP:-} == /dev/loop* ]] && losetup -d "$COW_LOOP"
fi
if [[ -f $IMAGE ]]; then
  losetup -j "$IMAGE" | awk -F: '{print $1}' | while read -r dev; do
    [[ -n $dev ]] && losetup -d "$dev"
  done
fi
if [[ -f $COW ]]; then
  losetup -j "$COW" | awk -F: '{print $1}' | while read -r dev; do
    [[ -n $dev ]] && losetup -d "$dev"
  done
fi
rm -f "$STATE_DIR/loops"
if findmnt -n --mountpoint "$MNT" >/dev/null 2>&1 || dmsetup info dashcam-origin >/dev/null 2>&1; then
  echo "dashcam storage is still busy" >&2
  exit 1
fi
exit 0
