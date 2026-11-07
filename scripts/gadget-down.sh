#!/bin/bash
# Take the USB drive offline. Idempotent.
set -euo pipefail
G=/sys/kernel/config/usb_gadget/dashcam
[[ -d $G ]] || exit 0
if [[ -f $G/UDC ]]; then
  printf '' >"$G/UDC" || true
fi
if [[ -f $G/functions/mass_storage.0/lun.0/file ]]; then
  printf '' >"$G/functions/mass_storage.0/lun.0/file" || true
fi
rm -f "$G/configs/c.1/mass_storage.0"
rmdir "$G/functions/mass_storage.0" 2>/dev/null || true
rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null || true
rmdir "$G/configs/c.1" 2>/dev/null || true
rmdir "$G/strings/0x409" 2>/dev/null || true
rmdir "$G" 2>/dev/null || true
exit 0
