#!/bin/bash
# Move files from the inbox share onto the drive the car writes.
#
# The car and the Pi must never write the same filesystem at once, so this
# takes the USB drive away from the car for the length of the copy. It waits
# for the upload to settle and for the car to stop writing, so it does not cut
# into a recording. A file leaves the inbox only once it is safely on the drive.
set -euo pipefail
HERE=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=common.sh
source "$HERE/common.sh"

APPLY_MNT=$STATE_DIR/apply
CAR_WRITES=$STATE_DIR/inbox-car-writes
FAILED_STAMP=$STATE_DIR/inbox-failed
INBOX_TMP_NAME=.dashcam-inbox.tmp
# A file that cannot be written waits this long, unless something new arrives.
# Without it, the car's drive would be disconnected at every idle check.
INBOX_RETRY_SECS=3600

gadget_detach() {
  "$HERE/gadget-down.sh"
}

gadget_attach() {
  "$HERE/gadget-up.sh"
}

# Sectors written to the origin. Snapshot copies go to the scratch file and the
# Pi's reads are not writes, so apart from this script's own copies, this only
# moves when the car writes.
car_write_sectors() {
  local dm
  dm=$(basename "$(readlink -f /dev/mapper/dashcam-origin)")
  awk '{print $7}' "/sys/block/$dm/stat"
}

# Print when the car last wrote, as far as this script has seen.
car_last_write() {
  local now=$1 sectors saved="" since=""
  sectors=$(car_write_sectors)
  if [[ -f $CAR_WRITES ]]; then
    read -r saved since <"$CAR_WRITES" || true
  fi
  if [[ $saved != "$sectors" || -z $since ]]; then
    since=$now
    printf '%s %s\n' "$sectors" "$since" >"$CAR_WRITES"
  fi
  printf '%s' "$since"
}

# ctime, because a Mac sets a copied file's mtime back to the original's.
inbox_newest_change() {
  local newest
  newest=$(find "$INBOX_MNT" ! -path "$INBOX_MNT/lost+found*" -printf '%C@\n' | sort -n | tail -1)
  printf '%s' "${newest%.*}"
}

inbox_file_open() {
  smbstatus -L 2>/dev/null | grep -F "$INBOX_MNT" >/dev/null
}

# Decide from timestamps alone: now, newest upload, last car write, last failure.
inbox_due() {
  local now=$1 newest=$2 car=$3 failed=$4
  ((now - newest >= INBOX_SETTLE_SECS)) || return 1
  ((now - car >= INBOX_IDLE_SECS)) || return 1
  if ((failed > 0 && newest <= failed && now - failed < INBOX_RETRY_SECS)); then
    return 1
  fi
  return 0
}

# Copy each file. APPLIED lists the ones now on the drive. Each file is copied
# beside its target and renamed, so the car never finds half a file.
inbox_copy_files() {
  local started=$SECONDS f rel dest dir tmp
  APPLIED=()
  APPLY_FAILED=0
  for f in "$@"; do
    if ((SECONDS - started >= INBOX_MAX_SECS)); then
      notice "reached the ${INBOX_MAX_SECS}s limit. The rest waits for the next idle window."
      break
    fi
    rel=${f#"$INBOX_MNT"/}
    dest=$APPLY_MNT/$rel
    dir=$(dirname -- "$dest")
    tmp=$dir/$INBOX_TMP_NAME
    # A symlink on the drive must not lead the copy onto the Pi's own disk.
    if [[ $(realpath -m -- "$dest") != "$APPLY_MNT"/* ]]; then
      warn "refusing $rel: the path leaves the drive. It stays in the inbox."
      APPLY_FAILED=1
      continue
    fi
    if [[ ! -d $dest ]] && mkdir -p -- "$dir" && cp -- "$f" "$tmp" && mv -f -- "$tmp" "$dest"; then
      APPLIED+=("$f")
      notice "wrote $rel"
    else
      rm -f -- "$tmp"
      warn "could not write $rel. It stays in the inbox."
      APPLY_FAILED=1
    fi
  done
}

# True when the drive is no longer mounted here. Unmounting flushes every write.
inbox_unmount_drive() {
  local _
  findmnt -n --mountpoint "$APPLY_MNT" >/dev/null 2>&1 || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if umount "$APPLY_MNT"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Runs on every way out of the copy. The car has to get its drive back, unless
# that would put two writers on one filesystem. A reboot clears that case.
inbox_restore() {
  if ! inbox_unmount_drive; then
    warn "could not unmount the drive, so it stays disconnected from the car. Reboot the Pi."
    return 0
  fi
  kpartx -d /dev/mapper/dashcam-origin >/dev/null 2>&1 || true
  if ((GADGET_WAS_UP)); then
    gadget_attach || warn "could not reconnect the USB drive to the car"
  fi
}

# Remove what reached the drive, with its macOS sidecar and any emptied folders.
inbox_clear_applied() {
  local f
  ((${#APPLIED[@]})) || return 0
  for f in "${APPLIED[@]}"; do
    rm -f -- "$f" "$(dirname -- "$f")/._$(basename -- "$f")"
  done
  find "$INBOX_MNT" -mindepth 1 -depth -type d -empty ! -name lost+found -delete 2>/dev/null || true
}

inbox_apply_now() {
  local dev
  GADGET_WAS_UP=0
  if [[ -d $GADGET_ROOT ]]; then
    GADGET_WAS_UP=1
  fi
  APPLIED=()
  APPLY_FAILED=0
  trap inbox_restore EXIT
  trap 'exit 143' TERM
  gadget_detach
  [[ ! -d $GADGET_ROOT/functions/mass_storage.0 ]] || die "the USB drive would not disconnect. Nothing was written."
  mkdir -p "$APPLY_MNT"
  dev=$(map_first_partition /dev/mapper/dashcam-origin)
  mount_drive_rw "$dev" "$APPLY_MNT" remount-ro
  # Left behind if the power went out in the middle of a copy.
  find "$APPLY_MNT" -type f -name "$INBOX_TMP_NAME" -delete 2>/dev/null || true
  inbox_copy_files "$@"
  if inbox_unmount_drive; then
    inbox_clear_applied
  else
    APPLY_FAILED=1
  fi
  if ((APPLY_FAILED)); then
    touch "$FAILED_STAMP"
  else
    rm -f "$FAILED_STAMP"
  fi
  # Make the next refresh show the new files.
  rm -f "$STATE_DIR/refresh-stamp"
  notice "wrote ${#APPLIED[@]} of $# waiting file(s) to the drive"
}

# Sourced by the tests. A normal run is not sourced, so `return` fails and we continue.
if [[ ${DASHCAM_TEST:-} == 1 ]]; then
  return 0 2>/dev/null || true
fi

require_root
load_env
[[ $SHARE == snapshot && $INBOX_GB -gt 0 ]] || exit 0
findmnt -n --mountpoint "$INBOX_MNT" >/dev/null || exit 0
lock_nowait || exit 0
origin_exists || exit 0

mapfile -d '' FILES < <(inbox_files)
((${#FILES[@]})) || exit 0

now=$(date +%s)
car=$(car_last_write "$now")
newest=$(inbox_newest_change)
failed=0
if [[ -f $FAILED_STAMP ]]; then
  failed=$(stat -c %Y "$FAILED_STAMP")
fi
inbox_due "$now" "$newest" "$car" "$failed" || exit 0
if inbox_file_open; then
  exit 0
fi

notice "the car is idle. Disconnecting its USB drive to write ${#FILES[@]} file(s)."
inbox_apply_now "${FILES[@]}"
