#!/bin/bash
# Take the USB drive offline. Idempotent.
set -euo pipefail
G=/sys/kernel/config/usb_gadget/dashcam
[[ -d $G ]] || exit 0
# echo, not printf '': configfs acts on a write, and printf '' never writes.
if [[ -f $G/UDC ]]; then
  echo >"$G/UDC" 2>/dev/null || true
fi
if [[ -f $G/functions/mass_storage.0/lun.0/file ]]; then
  echo >"$G/functions/mass_storage.0/lun.0/file" 2>/dev/null || true
fi
rm -f "$G/configs/c.1/mass_storage.0"
rmdir "$G/functions/mass_storage.0" 2>/dev/null || true
rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null || true
rmdir "$G/configs/c.1" 2>/dev/null || true
rmdir "$G/strings/0x409" 2>/dev/null || true
rmdir "$G" 2>/dev/null || true
exit 0
