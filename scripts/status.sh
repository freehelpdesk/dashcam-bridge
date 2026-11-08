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
  case "$model" in
    *"Pi 5"* | *"Compute Module 5"*)
      # The input voltage sagging toward 4.63 V is the port running out.
      supply=$(vcgencmd pmic_read_adc 2>/dev/null | awk '/EXT5V_V/ {print $NF; exit}' || true)
      printf 'supply voltage: %s\n' "${supply:-n/a}"
      printf 'usb limit: %s\n' "$(vcgencmd get_config usb_max_current_enable 2>/dev/null || echo n/a)"
      printf 'cpu limit: %s\n' "$(vcgencmd get_config arm_freq 2>/dev/null || echo n/a)"
      ;;
  esac
fi
if ((REDUCED_POWER)); then
  printf 'reduced power: on\n'
else
  printf 'reduced power: off\n'
fi
shopt -s nullglob
for ctrl in /sys/class/nvme/nvme*; do
  name=${ctrl##*/}
  state=n/a
  if command -v nvme >/dev/null 2>&1; then
    state=$(nvme get-feature "/dev/$name" --feature-id=2 2>/dev/null | awk -F'value:' 'NF > 1 {print $2; exit}' || true)
  fi
  printf '%s: %s, power state %s\n' "$name" "$(cat "$ctrl/device/current_link_speed" 2>/dev/null || echo n/a)" "${state:-n/a}"
done
shopt -u nullglob
if [[ -r /sys/kernel/config/usb_gadget/dashcam/configs/c.1/MaxPower ]]; then
  printf 'usb power requested: %s mA\n' "$(cat /sys/kernel/config/usb_gadget/dashcam/configs/c.1/MaxPower)"
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
  bound=$(cat /sys/kernel/config/usb_gadget/dashcam/UDC 2>/dev/null || true)
  printf 'gadget: %s\n' "${bound:-unbound}"
else
  printf 'gadget: down\n'
fi

if ((TELEMETRY)); then
  printf 'telemetry: scanner %s, api %s on port %s\n' \
    "$(systemctl is-active dashcam-telemetry-scan.service 2>/dev/null || true)" \
    "$(systemctl is-active dashcam-telemetry.service 2>/dev/null || true)" "$TELEMETRY_PORT"
fi
printf 'storage: %s\n' "$STORAGE"
printf 'share mode: %s\n' "$SHARE"
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
elif [[ $SHARE == live ]]; then
  printf 'snapshot: not used (SHARE=live)\n'
else
  printf 'snapshot: down\n'
fi

if findmnt -n --mountpoint /mnt/dashcam >/dev/null; then
  findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt/dashcam
  df -h --output=used,size,pcent /mnt/dashcam | awk 'NR==2 {printf "share used: %s of %s (%s)\n", $1, $2, $3}'
else
  printf 'share mount: down\n'
fi

if findmnt -n --mountpoint "$INBOX_MNT" >/dev/null; then
  mapfile -d '' pending < <(inbox_files)
  printf 'inbox: %s file(s) waiting, %s\n' "${#pending[@]}" \
    "$(df -h --output=avail "$INBOX_MNT" | awk 'NR==2 {print $1 " free"}')"
elif [[ $SHARE == snapshot && $INBOX_GB -gt 0 ]]; then
  printf 'inbox: down\n'
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
