#!/bin/bash
# Present /dev/mapper/dashcam-origin to the car as a USB drive.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root
load_env

[[ -b /dev/mapper/dashcam-origin ]] || die "dashcam-origin is missing; storage did not start"

modprobe libcomposite
modprobe dwc2 || true

if [[ -d $GADGET_ROOT && -s $GADGET_ROOT/UDC ]]; then
  exit 0
fi

if [[ -d $GADGET_ROOT ]]; then
  "$(dirname "${BASH_SOURCE[0]}")/gadget-down.sh"
fi

udc=""
for _ in $(seq 1 30); do
  udc=$(ls /sys/class/udc 2>/dev/null | head -1 || true)
  [[ -n $udc ]] && break
  sleep 1
done
[[ -n $udc ]] || die "USB device controller is missing. Reboot so config.txt can enable it."

serial=$(cut -c1-32 /etc/machine-id)
G=$GADGET_ROOT
mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
echo 0x1d6b >"$G/idVendor"
echo 0x0104 >"$G/idProduct"
echo 0x0200 >"$G/bcdUSB"
echo 0x0100 >"$G/bcdDevice"
echo "Dashcam Bridge" >"$G/strings/0x409/manufacturer"
echo "Dashcam Drive" >"$G/strings/0x409/product"
echo "$serial" >"$G/strings/0x409/serialnumber"
echo "TeslaCam" >"$G/configs/c.1/strings/0x409/configuration"
if [[ $POWER_SOURCE == external ]]; then
  # Self-powered. The car's port must not also feed 5 V.
  echo 0xC0 >"$G/configs/c.1/bmAttributes"
  echo 2 >"$G/configs/c.1/MaxPower"
else
  echo 0x80 >"$G/configs/c.1/bmAttributes"
  # configfs stores MaxPower in USB's 2 mA units, and the field maxes out at 255.
  # 250 asks the port for 500 mA, the USB 2 high-power ceiling.
  echo 250 >"$G/configs/c.1/MaxPower"
fi

mkdir -p "$G/functions/mass_storage.0"
echo 1 >"$G/functions/mass_storage.0/stall"
echo 0 >"$G/functions/mass_storage.0/lun.0/cdrom"
echo 0 >"$G/functions/mass_storage.0/lun.0/ro"
echo 1 >"$G/functions/mass_storage.0/lun.0/removable"
echo "$GADGET_NOFUA" >"$G/functions/mass_storage.0/lun.0/nofua"
echo /dev/mapper/dashcam-origin >"$G/functions/mass_storage.0/lun.0/file"
ln -s "$G/functions/mass_storage.0" "$G/configs/c.1/"
echo "$udc" >"$G/UDC"
log "gadget bound to $udc"
