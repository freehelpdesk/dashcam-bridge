#!/bin/bash
# Print the live state of the bridge.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root
load_env

model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "unknown")
printf 'model: %s\n' "$model"

if command -v vcgencmd >/dev/null 2>&1; then
  printf 'temp: %s\n' "$(vcgencmd measure_temp 2>/dev/null || echo n/a)"
  printf 'throttled: %s\n' "$(vcgencmd get_throttled 2>/dev/null || echo n/a)"
fi

shopt -s nullglob
found=0
for udc in /sys/class/udc/*; do
  found=1
  printf 'udc: %s state=%s\n' "$(basename "$udc")" "$(cat "$udc/state" 2>/dev/null || echo unknown)"
done
if ((found == 0)); then
  printf 'udc: none (reboot after provision if this persists)\n'
fi
shopt -u nullglob

if [[ -d /sys/kernel/config/usb_gadget/dashcam ]]; then
  printf 'gadget: %s\n' "$(cat /sys/kernel/config/usb_gadget/dashcam/UDC 2>/dev/null || echo unbound)"
else
  printf 'gadget: down\n'
fi

printf 'storage: %s\n' "$STORAGE"
if [[ -f $STATE_DIR/loops ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/loops"
fi
if [[ ${ORIGIN_LOOP:-} == /dev/sd* || ${ORIGIN_LOOP:-} == /dev/nvme* || ${ORIGIN_LOOP:-} == /dev/mmcblk* ]]; then
  printf 'clip disk: %s\n' "$ORIGIN_LOOP"
elif [[ $STORAGE == sd ]]; then
  printf 'clip disk: image file on %s\n' "$(findmnt -n -o SOURCE / 2>/dev/null || echo 'the boot disk')"
else
  printf 'clip disk: %s, or an image file if that disk is the boot disk\n' "$STORAGE"
fi

if [[ -f $IMAGE ]]; then
  printf 'image: %s\n' "$IMAGE"
  printf 'image apparent: %s\n' "$(du -h --apparent-size "$IMAGE" | awk '{print $1}')"
  printf 'image allocated: %s\n' "$(du -h "$IMAGE" | awk '{print $1}')"
else
  printf 'image: not created yet\n'
fi

if dmsetup info dashcam-snap >/dev/null 2>&1; then
  printf 'snapshot: %s\n' "$(dmsetup status dashcam-snap)"
  if pct=$(cow_percent); then
    printf 'snapshot scratch: %s%%\n' "$pct"
  fi
else
  printf 'snapshot: down\n'
fi

if findmnt -n --mountpoint /mnt/dashcam >/dev/null; then
  findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt/dashcam
else
  printf 'share mount: down\n'
fi

if ((${#NET_SSID[@]})); then
  printf 'saved networks:\n'
  for i in "${!NET_SSID[@]}"; do
    printf '  %s  priority %s\n' "${NET_SSID[$i]}" "${NET_PRI[$i]}"
  done
else
  printf 'saved networks: none\n'
fi
printf 'addresses:\n'
ip -4 -br addr
printf 'wifi:\n'
nmcli -t -f NAME,DEVICE,TYPE connection show --active || true
printf 'smb:\n'
smbstatus -b || true
