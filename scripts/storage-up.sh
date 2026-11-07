#!/bin/bash
# Present the dashcam disk and a device-mapper snapshot.
# STORAGE=sd uses an image file. STORAGE=usb and STORAGE=nvme use the drive itself.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_root
load_env
# shellcheck source=storage-disk.sh
source "$(dirname "${BASH_SOURCE[0]}")/storage-disk.sh"
lock_wait
if origin_exists; then
  "$(dirname "${BASH_SOURCE[0]}")/gadget-down.sh" || true
  release_dashcam_devices || die "could not release the previous dashcam disk"
fi
storage_prepare

modprobe loop
modprobe dm-snapshot

storage_ensure_cow() {
  local cow_bytes avail need
  [[ $SHARE == snapshot ]] || return 0
  cow_bytes=$((COW_GB * 1024 * 1024 * 1024))
  if [[ -f $COW ]] && [[ $(stat -c %s "$COW") -ge $cow_bytes ]]; then
    return 0
  fi
  if [[ ${STORAGE_RAW:-0} == 1 ]]; then
    avail=$(df -BG --output=avail "$IMAGE_DIR" | tail -1 | tr -dc '0-9')
    need=$((COW_GB + 1))
    if ((${avail:-0} < need)); then
      die "need ${need} GiB free on the boot disk for snapshot scratch, have ${avail:-0} GiB."
    fi
  fi
  truncate -s "${COW_GB}G" "$COW"
}

storage_attach() {
  if [[ ${STORAGE_RAW:-0} == 1 ]]; then
    [[ -b ${DATA_DISK:-} ]] || die "data disk ${DATA_DISK:-} is missing"
    storage_unmount_disk "$(basename "$DATA_DISK")"
    ORIGIN_LOOP=$DATA_DISK
  else
    ORIGIN_LOOP=$(attach_loop "$IMAGE")
  fi
  if [[ $SHARE == snapshot ]]; then
    COW_LOOP=$(attach_loop "$COW")
  else
    COW_LOOP=
  fi
  write_loops
}

storage_present() {
  local sz=$1
  if dmsetup info dashcam-snap >/dev/null 2>&1; then
    dmsetup remove dashcam-snap || true
  fi
  if dmsetup info dashcam-origin >/dev/null 2>&1; then
    dmsetup remove dashcam-origin || true
  fi
  if [[ $SHARE == live ]]; then
    dmsetup create dashcam-origin --table "0 ${sz} linear ${ORIGIN_LOOP} 0"
    return 0
  fi
  dmsetup create dashcam-snap --table "0 ${sz} snapshot ${ORIGIN_LOOP} ${COW_LOOP} N ${SNAP_CHUNK}"
  dmsetup create dashcam-origin --table "0 ${sz} snapshot-origin ${ORIGIN_LOOP}"
}

if origin_exists; then
  if [[ ! -f $STATE_DIR/loops ]]; then
    storage_ensure_cow
    storage_attach
  fi
  mount_share
  exit 0
fi

mkdir -p "$IMAGE_DIR"
if [[ ${STORAGE_RAW:-0} == 1 ]]; then
  storage_ensure_cow
  storage_attach
  storage_present "$(blockdev --getsz "$ORIGIN_LOOP")"
  mount_share
  exit 0
fi

while read -r dev; do
  [[ -n $dev ]] && losetup -d "$dev" || true
done < <(losetup -j "${IMAGE}.partial" 2>/dev/null | awk -F: '{print $1}')
rm -f "${IMAGE}.partial"
if [[ ! -f $IMAGE ]]; then
  avail=$(df -BG --output=avail "$IMAGE_DIR" | tail -1 | tr -dc '0-9')
  if [[ $SHARE == live ]]; then
    need=$((IMAGE_GB + 1))
  else
    need=$((IMAGE_GB + COW_GB + 2))
  fi
  if ((avail < need)); then
    die "need ${need} GiB free in $IMAGE_DIR, have ${avail} GiB. Lower IMAGE_GB or use a larger card."
  fi
  log "creating ${IMAGE_GB} GiB ${IMAGE_FS} image"
  partial="${IMAGE}.partial"
  truncate -s "${IMAGE_GB}G" "$partial"
  parted -s "$partial" mklabel msdos
  if [[ $IMAGE_FS == exfat ]]; then
    parted -s "$partial" mkpart primary ntfs 1MiB 100%
  else
    parted -s "$partial" mkpart primary ext4 1MiB 100%
  fi
  seed=$(losetup --find --show --partscan --sector-size 512 "$partial")
  part=${seed}p1
  udevadm settle || true
  for _ in $(seq 1 50); do
    [[ -b $part ]] && break
    partx -a "$seed" >/dev/null 2>&1 || true
    sleep 0.1
  done
  [[ -b $part ]] || die "partition $part did not appear"
  if [[ $IMAGE_FS == exfat ]]; then
    mkfs.exfat -n TESLA "$part"
  else
    mkfs.ext4 -F -L TESLA -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$part"
  fi
  mkdir -p /mnt/dashcam-seed
  mount "$part" /mnt/dashcam-seed
  mkdir -p /mnt/dashcam-seed/TeslaCam/RecentClips
  mkdir -p /mnt/dashcam-seed/TeslaCam/SavedClips
  mkdir -p /mnt/dashcam-seed/TeslaCam/SentryClips
  sync
  umount /mnt/dashcam-seed
  rmdir /mnt/dashcam-seed
  losetup -d "$seed" || {
    partx -d "$seed" || true
    losetup -d "$seed"
  }
  mv "$partial" "$IMAGE"
  log "image ready at $IMAGE"
fi

storage_ensure_cow
storage_attach
storage_present "$(blockdev --getsz "$ORIGIN_LOOP")"
mount_share
