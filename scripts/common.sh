# Shared helpers for dashcam-bridge. Sourced by the other scripts.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE=/etc/dashcam-bridge.env
MNT=/mnt/dashcam
STATE_DIR=/run/dashcam-bridge
GADGET_ROOT=/sys/kernel/config/usb_gadget/dashcam
LOCK_FILE=/run/dashcam-bridge/lock

log() {
  printf '%s\n' "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "run as root"
  fi
}

load_env() {
  [[ -f $ENV_FILE ]] || die "missing $ENV_FILE — run scripts/provision.sh"
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  : "${WIFI_COUNTRY:?WIFI_COUNTRY is required}"
  : "${WIFI_IFACE:=wlan0}"
  : "${HOME_SSID:=}"
  : "${HOME_PSK:=}"
  : "${WIFI_NET_1_SSID:=}"
  : "${WIFI_NET_1_PSK:=}"
  : "${WIFI_NET_1_PRIORITY:=}"
  : "${WIFI_NET_2_SSID:=}"
  : "${WIFI_NET_2_PSK:=}"
  : "${WIFI_NET_2_PRIORITY:=}"
  : "${WIFI_NET_3_SSID:=}"
  : "${WIFI_NET_3_PSK:=}"
  : "${WIFI_NET_3_PRIORITY:=}"
  : "${WIFI_NET_4_SSID:=}"
  : "${WIFI_NET_4_PSK:=}"
  : "${WIFI_NET_4_PRIORITY:=}"
  : "${WIFI_NET_5_SSID:=}"
  : "${WIFI_NET_5_PSK:=}"
  : "${WIFI_NET_5_PRIORITY:=}"
  : "${WIFI_NET_6_SSID:=}"
  : "${WIFI_NET_6_PSK:=}"
  : "${WIFI_NET_6_PRIORITY:=}"
  : "${WIFI_NET_7_SSID:=}"
  : "${WIFI_NET_7_PSK:=}"
  : "${WIFI_NET_7_PRIORITY:=}"
  : "${WIFI_NET_8_SSID:=}"
  : "${WIFI_NET_8_PSK:=}"
  : "${WIFI_NET_8_PRIORITY:=}"
  : "${AP_SSID:?AP_SSID is required}"
  : "${AP_PSK:?AP_PSK is required}"
  : "${SMB_USER:?SMB_USER is required}"
  : "${SMB_PASSWORD:?SMB_PASSWORD is required}"
  : "${IMAGE_DIR:?IMAGE_DIR is required}"
  : "${IMAGE_GB:?IMAGE_GB is required}"
  : "${COW_GB:?COW_GB is required}"
  : "${IMAGE_FS:?IMAGE_FS is required}"
  : "${STORAGE:=sd}"
  : "${SHARE:=live}"
  : "${GADGET_NOFUA:=0}"
  : "${POWER_SOURCE:=bus}"
  : "${SNAP_CHUNK:=32}"

  IMAGE_DIR=${IMAGE_DIR%/}
  [[ $IMAGE_DIR == /* && $IMAGE_DIR != / && $IMAGE_DIR != *[[:space:]]* ]] || die "IMAGE_DIR must be an absolute path without spaces"
  IMAGE="$IMAGE_DIR/cam.img"
  COW="$IMAGE_DIR/cow.img"
  mkdir -p "$STATE_DIR"
  validate_env
}

validate_env() {
  [[ $WIFI_COUNTRY =~ ^[A-Za-z]{2}$ ]] || die "WIFI_COUNTRY must be two letters"
  [[ $AP_PSK != "CHANGEME" && ${#AP_PSK} -ge 8 ]] || die "set AP_PSK in $ENV_FILE to 8 or more characters"
  [[ $SMB_PASSWORD != "CHANGEME" && ${#SMB_PASSWORD} -ge 8 ]] || die "set SMB_PASSWORD in $ENV_FILE to 8 or more characters"
  [[ $SMB_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SMB_USER must be a simple username"
  [[ $IMAGE_GB =~ ^[0-9]+$ && $IMAGE_GB -ge 64 && $IMAGE_GB -le 1900 ]] || die "IMAGE_GB must be 64–1900"
  [[ $COW_GB =~ ^[0-9]+$ && $COW_GB -ge 4 ]] || die "COW_GB must be at least 4"
  [[ $IMAGE_FS == "ext4" || $IMAGE_FS == "exfat" ]] || die "IMAGE_FS must be ext4 or exfat"
  [[ $STORAGE == "sd" || $STORAGE == "nvme" || $STORAGE == "usb" ]] || die "STORAGE must be sd, nvme, or usb"
  [[ $SHARE == "live" || $SHARE == "snapshot" ]] || die "SHARE must be live or snapshot"
  [[ $GADGET_NOFUA == "0" || $GADGET_NOFUA == "1" ]] || die "GADGET_NOFUA must be 0 or 1"
  [[ $POWER_SOURCE == "bus" || $POWER_SOURCE == "external" ]] || die "POWER_SOURCE must be bus or external"
  [[ $SNAP_CHUNK =~ ^[0-9]+$ ]] || die "SNAP_CHUNK must be a number"
  [[ $AP_PSK != -* ]] || die "AP_PSK cannot start with a dash"
  [[ $AP_SSID != *$'\n'* && $AP_PSK != *$'\n'* && $SMB_PASSWORD != *$'\n'* ]] || die "passwords must be a single line"
  load_networks
}

# Fill NET_SSID, NET_PSK, NET_PRI, and NET_CON from WIFI_NET_1..8.
# HOME_SSID is still accepted, as one more network at priority 100.
load_networks() {
  local i ssid_var psk_var pri_var ssid psk pri
  NET_SSID=()
  NET_PSK=()
  NET_PRI=()
  NET_CON=()
  [[ -z ${WIFI_NET_9_SSID:-} ]] || die "only 8 Wi-Fi networks are supported (WIFI_NET_1 .. WIFI_NET_8)"
  for i in 1 2 3 4 5 6 7 8; do
    ssid_var="WIFI_NET_${i}_SSID"
    psk_var="WIFI_NET_${i}_PSK"
    pri_var="WIFI_NET_${i}_PRIORITY"
    ssid=""
    psk=""
    pri=""
    if [[ -v $ssid_var ]]; then
      ssid=${!ssid_var}
    fi
    [[ -n $ssid ]] || continue
    if [[ -v $psk_var ]]; then
      psk=${!psk_var}
    fi
    if [[ -v $pri_var ]]; then
      pri=${!pri_var}
    fi
    # Blank priority: slot 1 is 100, slot 2 is 90, slot 3 is 80, and so on.
    [[ -n $pri ]] || pri=$((100 - (i - 1) * 10))
    check_network "$ssid" "$psk" "$pri" "WIFI_NET_${i}"
    if network_known "$ssid"; then
      die "Wi-Fi SSID ${ssid} is listed more than once"
    fi
    NET_SSID+=("$ssid")
    NET_PSK+=("$psk")
    NET_PRI+=("$pri")
    NET_CON+=("dashcam-net-${i}")
  done
  if [[ -n ${HOME_SSID:-} ]] && ! network_known "$HOME_SSID"; then
    check_network "$HOME_SSID" "${HOME_PSK:-}" 100 "HOME_SSID"
    NET_SSID+=("$HOME_SSID")
    NET_PSK+=("$HOME_PSK")
    NET_PRI+=(100)
    NET_CON+=("dashcam-net-home")
  fi
}

network_known() {
  local existing
  ((${#NET_SSID[@]})) || return 1
  for existing in "${NET_SSID[@]}"; do
    [[ $existing == "$1" ]] && return 0
  done
  return 1
}

check_network() {
  local ssid=$1 psk=$2 pri=$3 label=$4
  [[ $ssid != *$'\n'* && $ssid != *$'\t'* && $psk != *$'\n'* ]] || die "${label} must be a single line"
  [[ $ssid != *'#'* ]] || die "${label} SSID cannot contain #"
  [[ ${#ssid} -ge 1 && ${#ssid} -le 32 ]] || die "${label} SSID must be 1–32 characters"
  [[ ${#psk} -ge 8 && ${#psk} -le 63 ]] || die "set ${label} PSK to 8–63 characters"
  [[ $psk != -* ]] || die "${label} PSK cannot start with a dash"
  [[ $psk != "CHANGEME" ]] || die "set ${label} PSK in $ENV_FILE"
  [[ $pri =~ ^-?[0-9]+$ ]] || die "${label} priority must be a number"
}

# Read "ssid<TAB>signal" rows and rank saved networks.
# Higher priority wins. Same priority: stronger signal wins.
rank_saved_networks() {
  local -A seen=()
  local ssid sig i pri line
  local -a cand=()
  RANK_CON=()
  RANK_SSID=()
  RANK_PRI=()
  RANK_SIG=()
  while IFS=$'\t' read -r ssid sig; do
    [[ -n $ssid && $sig =~ ^[0-9]+$ ]] || continue
    if [[ -z ${seen[$ssid]:-} || $sig -gt ${seen[$ssid]} ]]; then
      seen[$ssid]=$sig
    fi
  done
  ((${#NET_SSID[@]})) || return 1
  for i in "${!NET_SSID[@]}"; do
    ssid=${NET_SSID[$i]}
    [[ -n ${seen[$ssid]:-} ]] || continue
    pri=${NET_PRI[$i]}
    sig=${seen[$ssid]}
    cand+=("${pri} ${sig} ${i}")
  done
  ((${#cand[@]})) || return 1
  while read -r pri sig i; do
    RANK_PRI+=("$pri")
    RANK_SIG+=("$sig")
    RANK_SSID+=("${NET_SSID[$i]}")
    RANK_CON+=("${NET_CON[$i]}")
  done < <(printf '%s\n' "${cand[@]}" | sort -k1,1nr -k2,2nr -k3,3n)
}

lock_wait() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock 9
}

lock_nowait() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9
}

origin_exists() {
  dmsetup info dashcam-origin >/dev/null 2>&1
}

write_loops() {
  printf 'ORIGIN_LOOP=%s\nCOW_LOOP=%s\n' "$ORIGIN_LOOP" "$COW_LOOP" >"$STATE_DIR/loops"
}

load_loops() {
  [[ -f $STATE_DIR/loops ]] || die "storage is not up"
  # shellcheck disable=SC1091
  source "$STATE_DIR/loops"
  : "${ORIGIN_LOOP:?}"
  : "${COW_LOOP:?}"
}

attach_loop() {
  local file=$1 existing dev
  existing=$(losetup -j "$file" | awk -F: 'NR==1 {print $1}')
  if [[ -n $existing ]]; then
    printf '%s' "$existing"
    return 0
  fi
  if dev=$(losetup --find --show --direct-io=on --sector-size 512 "$file" 2>/dev/null); then
    printf '%s' "$dev"
    return 0
  fi
  losetup --find --show --sector-size 512 "$file"
}

smb_busy() {
  smbstatus -b 2>/dev/null | grep -E 'SMB[23]' >/dev/null
}

cow_percent() {
  local alloc total
  read -r alloc total < <(dmsetup status dashcam-snap 2>/dev/null | awk '{split($4, a, "/"); print a[1], a[2]}')
  [[ -n ${total:-} && $total -gt 0 ]] || return 1
  echo $((alloc * 100 / total))
}

mount_share() {
  local name dev fstype base
  mkdir -p "$MNT"
  if findmnt -n --mountpoint "$MNT" >/dev/null; then
    return 0
  fi
  if [[ $SHARE == live ]]; then
    base=/dev/mapper/dashcam-origin
  else
    base=/dev/mapper/dashcam-snap
  fi
  kpartx -as "$base" >/dev/null 2>&1 || true
  udevadm settle || true
  name=$(kpartx -l "$base" | awk 'NR==1 {print $1}')
  if [[ -n $name ]]; then
    dev=/dev/mapper/$name
  else
    dev=$base
  fi
  local _
  for _ in $(seq 1 50); do
    [[ -b $dev ]] && break
    sleep 0.1
  done
  [[ -b $dev ]] || die "snapshot device $dev did not appear"
  fstype=$(blkid -o value -s TYPE "$dev" || true)
  case "$fstype" in
    ext4)
      if [[ $SHARE == live ]]; then
        # noload does not replay the journal, so this mount does not write
        # the disk the USB host is also using.
        mount -t ext4 -o ro,noload,noatime "$dev" "$MNT"
      else
        if ! mount -t ext4 -o noatime "$dev" "$MNT"; then
          e2fsck -p "$dev" || true
          mount -t ext4 -o noatime "$dev" "$MNT"
        fi
        mount -o remount,ro "$MNT"
      fi
      ;;
    exfat)
      mount -t exfat -o ro,noatime,umask=022 "$dev" "$MNT"
      ;;
    vfat)
      mount -t vfat -o ro,noatime,umask=022 "$dev" "$MNT"
      ;;
    *)
      die "unrecognized filesystem '${fstype:-unknown}' on $dev"
      ;;
  esac
  log "share mounted ($fstype)"
}

live_refresh() {
  local dev
  dev=$(findmnt -n -o SOURCE --mountpoint "$MNT" 2>/dev/null || true)
  blockdev --flushbufs /dev/mapper/dashcam-origin 2>/dev/null || true
  [[ -n $dev ]] && blockdev --flushbufs "$dev" 2>/dev/null || true
  sync || true
  # USB writes land on the block device, not in this mount's cache.
  echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
}

refresh_snapshot() {
  local suspended=0
  cleanup() {
    if ((suspended == 1)); then
      dmsetup resume dashcam-origin || true
      suspended=0
    fi
  }
  trap cleanup RETURN

  load_loops
  if findmnt -n --mountpoint "$MNT" >/dev/null; then
    sync || true
    if ! umount "$MNT"; then
      log "snapshot is busy; leaving the current view in place"
      return 0
    fi
  fi
  kpartx -d /dev/mapper/dashcam-snap >/dev/null 2>&1 || true
  blockdev --flushbufs /dev/mapper/dashcam-origin || true
  dmsetup suspend dashcam-origin
  suspended=1
  dmsetup remove dashcam-snap
  dd if=/dev/zero of="$COW_LOOP" bs=1M count=4 conv=notrunc status=none
  dmsetup create dashcam-snap --table "0 $(blockdev --getsz "$ORIGIN_LOOP") snapshot ${ORIGIN_LOOP} ${COW_LOOP} N ${SNAP_CHUNK}"
  dmsetup resume dashcam-origin
  suspended=0
  udevadm settle || true
  mount_share
}
