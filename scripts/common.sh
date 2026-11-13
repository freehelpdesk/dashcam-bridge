# Shared helpers for dashcam-bridge. Sourced by the other scripts.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE=/etc/dashcam-bridge.env
MNT=/mnt/dashcam
STATE_DIR=/run/dashcam-bridge
GADGET_ROOT=/sys/kernel/config/usb_gadget/dashcam
LOCK_FILE=/run/dashcam-bridge/lock
INBOX_MNT=/mnt/dashcam-inbox
TELEMETRY_ALERT_NAMES=(hard_brake hard_accel hard_corner impact swerve pothole autopilot_takeover lane_no_blinker blinker_left_on speeding geofence unexpected_use trip_summary sentry_event saved_clip recording_stopped power_trouble storage_full telemetry_lost)

log() {
  printf '%s\n' "$*"
}

# Under systemd, a <N> prefix sets the journal priority. dashcam-refresh keeps
# only notice and above, so its warnings and failures have to be marked.
notice() {
  printf '%s%s\n' "${JOURNAL_STREAM:+<5>}" "$*"
}

warn() {
  printf '%s%s\n' "${JOURNAL_STREAM:+<4>}" "$*" >&2
}

die() {
  printf '%s%s\n' "${JOURNAL_STREAM:+<3>}" "$*" >&2
  exit 1
}

# Drive the glovebox carrier's USB mux. dh hands the car this gadget.
# dl hands it back to the passthrough socket. An empty USB_TAKEOVER_GPIO,
# or a Pi without pinctrl, leaves the pin alone.
usb_takeover() {
  local level=$1 gpio=${USB_TAKEOVER_GPIO-}
  if [[ -z $gpio && -f $ENV_FILE ]]; then
    gpio=$(grep -E '^USB_TAKEOVER_GPIO=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d "\"'\r" || true)
  fi
  [[ -n $gpio ]] || return 0
  if ! command -v pinctrl >/dev/null 2>&1; then
    warn "pinctrl is not installed; USB passthrough mux left unchanged"
    return 0
  fi
  if pinctrl set "$gpio" op "$level"; then
    if [[ $level == dh ]]; then
      log "USB mux GPIO ${gpio} high, car sees this gadget"
    else
      log "USB mux GPIO ${gpio} low, car sees the passthrough socket"
    fi
  else
    warn "could not drive GPIO ${gpio}; USB mux left unchanged"
  fi
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
  : "${AP_SSID:?AP_SSID is required}"
  : "${AP_PSK:?AP_PSK is required}"
  : "${SMB_USER:?SMB_USER is required}"
  : "${SMB_PASSWORD:?SMB_PASSWORD is required}"
  : "${IMAGE_DIR:?IMAGE_DIR is required}"
  : "${IMAGE_GB:?IMAGE_GB is required}"
  : "${COW_GB:?COW_GB is required}"
  : "${IMAGE_FS:?IMAGE_FS is required}"
  : "${STORAGE:=sd}"
  : "${SHARE:=snapshot}"
  : "${GADGET_NOFUA:=0}"
  : "${POWER_SOURCE:=bus}"
  : "${REDUCED_POWER:=0}"
  : "${USB_TAKEOVER_GPIO:=}"
  : "${TELEMETRY:=0}"
  : "${TELEMETRY_TOKEN:=}"
  : "${TELEMETRY_PORT:=8088}"
  : "${TELEMETRY_BIND:=0.0.0.0}"
  : "${TELEMETRY_POLL_SECS:=10}"
  : "${TELEMETRY_BRAKE_MPS2:=4}"
  : "${TELEMETRY_ACCEL_MPS2:=4}"
  : "${TELEMETRY_CORNER_MPS2:=4}"
  : "${TELEMETRY_HOLD_MS:=250}"
  : "${TELEMETRY_KEEP_DAYS:=30}"
  : "${TELEMETRY_WEBHOOK_URL:=}"
  : "${TELEMETRY_WEBHOOK_FORMAT:=json}"
  : "${TELEMETRY_WEBHOOK_GPS:=0}"
  : "${TELEMETRY_WRITE_LOG:=0}"
  : "${SNAP_CHUNK:=32}"
  : "${INBOX_GB:=4}"
  : "${INBOX_IDLE_SECS:=120}"
  : "${INBOX_SETTLE_SECS:=60}"
  : "${INBOX_MAX_SECS:=60}"

  IMAGE_DIR=${IMAGE_DIR%/}
  [[ $IMAGE_DIR == /* && $IMAGE_DIR != / && $IMAGE_DIR != *[[:space:]]* ]] || die "IMAGE_DIR must be an absolute path without spaces"
  IMAGE="$IMAGE_DIR/cam.img"
  COW="$IMAGE_DIR/cow.img"
  INBOX_IMG="$IMAGE_DIR/inbox.img"
  mkdir -p "$STATE_DIR"
  validate_env
}

validate_env() {
  [[ $WIFI_COUNTRY =~ ^[A-Za-z]{2}$ ]] || die "WIFI_COUNTRY must be two letters"
  [[ ${#AP_SSID} -le 32 ]] || die "AP_SSID must be 1–32 characters"
  [[ $AP_PSK != "CHANGEME" && ${#AP_PSK} -ge 8 && ${#AP_PSK} -le 63 ]] || die "set AP_PSK in $ENV_FILE to 8–63 characters"
  [[ $SMB_PASSWORD != "CHANGEME" && ${#SMB_PASSWORD} -ge 8 ]] || die "set SMB_PASSWORD in $ENV_FILE to 8 or more characters"
  [[ $SMB_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "SMB_USER must be a simple username"
  [[ $IMAGE_GB =~ ^[0-9]+$ && $IMAGE_GB -ge 64 && $IMAGE_GB -le 1900 ]] || die "IMAGE_GB must be 64–1900"
  [[ $COW_GB =~ ^[0-9]+$ && $COW_GB -ge 4 ]] || die "COW_GB must be at least 4"
  [[ $IMAGE_FS == "ext4" || $IMAGE_FS == "exfat" ]] || die "IMAGE_FS must be ext4 or exfat"
  [[ $STORAGE == "sd" || $STORAGE == "nvme" || $STORAGE == "usb" ]] || die "STORAGE must be sd, nvme, or usb"
  [[ $SHARE == "live" || $SHARE == "snapshot" ]] || die "SHARE must be live or snapshot"
  [[ $GADGET_NOFUA == "0" || $GADGET_NOFUA == "1" ]] || die "GADGET_NOFUA must be 0 or 1"
  [[ $POWER_SOURCE == "bus" || $POWER_SOURCE == "external" ]] || die "POWER_SOURCE must be bus or external"
  [[ $REDUCED_POWER == "0" || $REDUCED_POWER == "1" ]] || die "REDUCED_POWER must be 0 or 1"
  [[ -z ${USB_TAKEOVER_GPIO:-} || ${USB_TAKEOVER_GPIO} =~ ^([0-9]|1[0-9]|2[0-7])$ ]] || die "USB_TAKEOVER_GPIO must be empty or a GPIO number 0-27"
  [[ $SNAP_CHUNK =~ ^[1-9][0-9]*$ ]] && ! ((SNAP_CHUNK & (SNAP_CHUNK - 1))) || die "SNAP_CHUNK must be a power of two"
  [[ $INBOX_GB =~ ^[0-9]+$ ]] || die "INBOX_GB must be a number (0 turns the inbox off)"
  [[ $INBOX_IDLE_SECS =~ ^[0-9]+$ && $INBOX_SETTLE_SECS =~ ^[0-9]+$ && $INBOX_MAX_SECS =~ ^[1-9][0-9]*$ ]] || die "INBOX_IDLE_SECS, INBOX_SETTLE_SECS, and INBOX_MAX_SECS must be numbers of seconds"
  [[ $AP_PSK != -* ]] || die "AP_PSK cannot start with a dash"
  [[ $AP_SSID != *$'\n'* && $AP_PSK != *$'\n'* && $SMB_PASSWORD != *$'\n'* ]] || die "passwords must be a single line"
  validate_telemetry
  load_networks
}

validate_telemetry() {
  local name value alert key
  [[ $TELEMETRY == "0" || $TELEMETRY == "1" ]] || die "TELEMETRY must be 0 or 1"
  [[ $TELEMETRY_WRITE_LOG == "0" || $TELEMETRY_WRITE_LOG == "1" ]] || die "TELEMETRY_WRITE_LOG must be 0 or 1"
  if ((TELEMETRY == 0)); then
    ((TELEMETRY_WRITE_LOG == 0)) || die "TELEMETRY_WRITE_LOG needs TELEMETRY=1"
    return 0
  fi
  # GPS history is behind this token, so a placeholder or a short one will not do.
  [[ $TELEMETRY_TOKEN != "CHANGEME" && ${#TELEMETRY_TOKEN} -ge 16 && $TELEMETRY_TOKEN =~ ^[[:graph:]]+$ ]] || die "set TELEMETRY_TOKEN in $ENV_FILE to 16 or more characters, with no spaces"
  [[ $TELEMETRY_PORT =~ ^[0-9]+$ && $TELEMETRY_PORT -ge 1024 && $TELEMETRY_PORT -le 65535 ]] || die "TELEMETRY_PORT must be 1024–65535"
  [[ $TELEMETRY_BIND =~ ^[0-9A-Fa-f:.]+$ ]] || die "TELEMETRY_BIND must be an IP address"
  [[ $TELEMETRY_POLL_SECS =~ ^[0-9]+$ && $TELEMETRY_POLL_SECS -ge 5 ]] || die "TELEMETRY_POLL_SECS must be at least 5"
  [[ $TELEMETRY_HOLD_MS =~ ^[0-9]+$ && $TELEMETRY_HOLD_MS -ge 50 ]] || die "TELEMETRY_HOLD_MS must be at least 50"
  [[ $TELEMETRY_KEEP_DAYS =~ ^[1-9][0-9]*$ ]] || die "TELEMETRY_KEEP_DAYS must be at least 1"
  for name in TELEMETRY_BRAKE_MPS2 TELEMETRY_ACCEL_MPS2 TELEMETRY_CORNER_MPS2; do
    value=${!name}
    [[ $value =~ ^[0-9]+(\.[0-9]+)?$ && ! $value =~ ^0+(\.0+)?$ ]] || die "$name must be a number above 0"
  done
  [[ -z $TELEMETRY_WEBHOOK_URL || $TELEMETRY_WEBHOOK_URL == http://* || $TELEMETRY_WEBHOOK_URL == https://* ]] || die "TELEMETRY_WEBHOOK_URL must start with http:// or https://"
  [[ $TELEMETRY_WEBHOOK_FORMAT == "json" || $TELEMETRY_WEBHOOK_FORMAT == "text" ]] || die "TELEMETRY_WEBHOOK_FORMAT must be json or text"
  [[ $TELEMETRY_WEBHOOK_GPS == "0" || $TELEMETRY_WEBHOOK_GPS == "1" ]] || die "TELEMETRY_WEBHOOK_GPS must be 0 or 1"
  for alert in "${TELEMETRY_ALERT_NAMES[@]}"; do
    key=TELEMETRY_ALERT_${alert^^}
    value=${!key:-}
    [[ -z $value || $value == off || $value == log || $value == alert ]] || die "$key must be off, log, or alert"
    name=${key}_WEBHOOK
    value=${!name:-}
    [[ -z $value || $value == http://* || $value == https://* ]] || die "$name must start with http:// or https://"
    name=${key}_WEBHOOK_FORMAT
    value=${!name:-}
    [[ -z $value || $value == json || $value == text ]] || die "$name must be json or text"
  done
  # A blank number uses the default.
  for name in TELEMETRY_IMPACT_MPS2 TELEMETRY_POTHOLE_MPS2 TELEMETRY_SWERVE_STEER_DEG TELEMETRY_SWERVE_MPS2 \
    TELEMETRY_SWERVE_MIN_MPH TELEMETRY_TAKEOVER_WINDOW_SECS TELEMETRY_TAKEOVER_BRAKE_MPS2 TELEMETRY_TAKEOVER_STEER_DPS \
    TELEMETRY_LANE_MIN_MPH TELEMETRY_BLINKER_SECS TELEMETRY_BLINKER_MIN_MPH TELEMETRY_SPEEDING_MPH TELEMETRY_SPEEDING_SECS \
    TELEMETRY_TRIP_MIN_MILES TELEMETRY_RECORDING_STOPPED_SECS TELEMETRY_DRIVE_FULL_PCT TELEMETRY_SCRATCH_FULL_PCT TELEMETRY_SEI_LOST_CLIPS; do
    value=${!name:-}
    [[ -z $value || $value =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$name must be a number"
  done
  local zone='[A-Za-z0-9_-]+:-?[0-9.]+,-?[0-9.]+:[0-9.]+'
  value=${TELEMETRY_GEOFENCE_ZONES:-}
  [[ -z $value || $value =~ ^$zone(;$zone)*\;?$ ]] || die "TELEMETRY_GEOFENCE_ZONES must look like home:37.5,-122.1:150;work:37.4,-122.0:200"
  zone="$zone:[0-9.]+"
  value=${TELEMETRY_SPEEDING_ZONES:-}
  [[ -z $value || $value =~ ^$zone(;$zone)*\;?$ ]] || die "TELEMETRY_SPEEDING_ZONES must look like school:37.5,-122.1:300:25"
  value=${TELEMETRY_UNEXPECTED_AREA:-}
  [[ -z $value || $value =~ ^-?[0-9.]+,-?[0-9.]+:[0-9.]+$ ]] || die "TELEMETRY_UNEXPECTED_AREA must look like 37.5,-122.1:50000"
  value=${TELEMETRY_UNEXPECTED_HOURS:-}
  [[ -z $value || ( $value =~ ^([0-9]{1,2})-([0-9]{1,2})$ && 10#${BASH_REMATCH[1]} -le 23 && 10#${BASH_REMATCH[2]} -le 23 ) ]] || die "TELEMETRY_UNEXPECTED_HOURS must look like 23-5"
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
  local ssid sig i pri
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

# Drop the share mount and the device-mapper devices. The live share maps a
# partition of dashcam-origin, and that map has to go before the origin can.
release_dashcam_devices() {
  local dev try unmounted=0
  if findmnt -n --mountpoint "$INBOX_MNT" >/dev/null 2>&1; then
    smbcontrol smbd close-share dashcam-inbox >/dev/null 2>&1 || true
    # Lazy is safe here: the inbox is its own filesystem, and nothing else uses it.
    umount "$INBOX_MNT" 2>/dev/null || umount -l "$INBOX_MNT" || true
  fi
  if findmnt -n --mountpoint "$MNT" >/dev/null 2>&1; then
    sync || true
    # A connected SMB client pins the mount, and it can reconnect between tries.
    for try in 1 2 3 4 5 6 7 8 9 10; do
      smbcontrol smbd close-share dashcam >/dev/null 2>&1 || true
      if umount "$MNT" 2>/dev/null; then
        unmounted=1
        break
      fi
      log "waiting for $MNT to go idle ($try)"
      sleep 0.5
    done
    ((unmounted)) || return 1
  fi
  # A telemetry scanner that was killed can leave its view open on the origin.
  umount "$STATE_DIR/telemetry" 2>/dev/null || true
  dmsetup remove dashcam-telem >/dev/null 2>&1 || true
  kpartx -d /dev/mapper/dashcam-origin >/dev/null 2>&1 || true
  kpartx -d /dev/mapper/dashcam-snap >/dev/null 2>&1 || true
  dmsetup remove dashcam-snap >/dev/null 2>&1 || true
  if dmsetup info dashcam-origin >/dev/null 2>&1; then
    dmsetup resume dashcam-origin >/dev/null 2>&1 || true
    dmsetup remove dashcam-origin >/dev/null 2>&1 || dmsetup remove -f dashcam-origin >/dev/null 2>&1 || return 1
  fi
  if [[ -f $STATE_DIR/loops ]]; then
    # shellcheck disable=SC1091
    source "$STATE_DIR/loops"
    [[ ${ORIGIN_LOOP:-} == /dev/loop* ]] && losetup -d "$ORIGIN_LOOP" >/dev/null 2>&1 || true
    [[ ${COW_LOOP:-} == /dev/loop* ]] && losetup -d "$COW_LOOP" >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/loops"
  fi
  for dev in "$IMAGE" "$COW"; do
    [[ -f $dev ]] || continue
    losetup -j "$dev" 2>/dev/null | awk -F: '{print $1}' | while read -r loop; do
      [[ -n $loop ]] && losetup -d "$loop"
    done || true
  done
  if origin_exists; then
    return 1
  fi
  return 0
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

share_is_ro() {
  findmnt -n -o OPTIONS --mountpoint "$MNT" 2>/dev/null | grep -Eq '(^|,)ro(,|$)'
}

# Map the first partition of a device-mapper disk. Prints the device to mount,
# which is the disk itself when it has no partition table.
map_first_partition() {
  local base=$1 name dev _
  kpartx -as "$base" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true
  # No partition table is fine: the car can format the whole device.
  name=$(kpartx -l "$base" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  if [[ -n $name ]]; then
    dev=/dev/mapper/$name
  else
    dev=$base
  fi
  for _ in $(seq 1 50); do
    [[ -b $dev ]] && break
    sleep 0.1
  done
  [[ -b $dev ]] || die "device $dev did not appear"
  printf '%s' "$dev"
}

# Mount the drive read-write. Only call this while nothing else can write it.
mount_drive_rw() {
  local dev=$1 mnt=$2 errors=$3 fstype
  fstype=$(blkid -o value -s TYPE "$dev" || true)
  case "$fstype" in
    ext4)
      # The car losing power mid-write is routine, so a repair may be needed.
      if ! mount -t ext4 -o "rw,noatime,errors=${errors}" "$dev" "$mnt"; then
        e2fsck -p "$dev" || true
        mount -t ext4 -o "rw,noatime,errors=${errors}" "$dev" "$mnt"
      fi
      ;;
    exfat | vfat)
      mount -t "$fstype" -o rw,noatime,umask=022 "$dev" "$mnt"
      ;;
    *)
      die "unrecognized filesystem '${fstype:-unknown}' on $dev"
      ;;
  esac
}

# Files waiting on the inbox share, NUL-separated. macOS sidecars are not files
# the user meant to send.
inbox_files() {
  find "$INBOX_MNT" -type f ! -name '._*' ! -name .DS_Store ! -path "$INBOX_MNT/lost+found/*" -print0
}

# The inbox is a fixed-size image, fully allocated up front. A big upload then
# cannot fill the boot disk that also holds the car's clips.
inbox_up() {
  local avail need partial
  [[ $SHARE == snapshot && $INBOX_GB -gt 0 ]] || return 0
  mkdir -p "$INBOX_MNT"
  if findmnt -n --mountpoint "$INBOX_MNT" >/dev/null; then
    return 0
  fi
  if [[ ! -f $INBOX_IMG ]]; then
    avail=$(df -BG --output=avail "$IMAGE_DIR" | tail -1 | tr -dc '0-9')
    need=$((INBOX_GB + 1))
    ((${avail:-0} >= need)) || die "need ${need} GiB free for the inbox, have ${avail:-0} GiB. Lower INBOX_GB."
    partial="${INBOX_IMG}.partial"
    rm -f "$partial"
    fallocate -l "${INBOX_GB}G" "$partial"
    mkfs.ext4 -F -q -m 0 -L dashcam-inbox "$partial"
    mv "$partial" "$INBOX_IMG"
    log "created ${INBOX_GB} GiB inbox"
  fi
  if ! mount -o loop,noatime "$INBOX_IMG" "$INBOX_MNT"; then
    e2fsck -p "$INBOX_IMG" || true
    mount -o loop,noatime "$INBOX_IMG" "$INBOX_MNT"
  fi
  log "inbox mounted at $INBOX_MNT"
}

mount_share() {
  local dev fstype base src
  mkdir -p "$MNT"
  if findmnt -n --mountpoint "$MNT" >/dev/null; then
    if [[ $SHARE == live ]] && share_is_ro; then
      src=$(findmnt -n -o SOURCE --mountpoint "$MNT")
      blockdev --setrw "$src" 2>/dev/null || true
      fstype=$(findmnt -n -o FSTYPE --mountpoint "$MNT")
      if [[ $fstype == ext4 ]]; then
        mount -o remount,rw,errors=continue "$MNT" || die "could not remount $MNT read-write"
      else
        mount -o remount,rw "$MNT" || die "could not remount $MNT read-write"
      fi
      log "share remounted read-write"
    fi
    return 0
  fi
  if [[ $SHARE == live ]]; then
    base=/dev/mapper/dashcam-origin
  else
    base=/dev/mapper/dashcam-snap
  fi
  dev=$(map_first_partition "$base")
  blockdev --setrw "$dev" 2>/dev/null || true
  fstype=$(blkid -o value -s TYPE "$dev" || true)
  if [[ $SHARE == live ]]; then
    # errors=continue keeps ext4 from flipping the share back to read-only
    # when the USB host has also touched the filesystem. The repair inside is
    # safe because storage always comes up before the gadget exports the disk.
    mount_drive_rw "$dev" "$MNT" continue
  else
    case "$fstype" in
      ext4)
        if ! mount -t ext4 -o noatime "$dev" "$MNT"; then
          e2fsck -p "$dev" || true
          mount -t ext4 -o noatime "$dev" "$MNT"
        fi
        mount -o remount,ro "$MNT"
        ;;
      exfat | vfat)
        mount -t "$fstype" -o ro,noatime,umask=022 "$dev" "$MNT"
        ;;
      *)
        die "unrecognized filesystem '${fstype:-unknown}' on $dev"
        ;;
    esac
  fi
  if [[ $SHARE == live ]] && share_is_ro; then
    die "share stayed read-only ($(findmnt -n -o OPTIONS --mountpoint "$MNT" 2>/dev/null || echo unknown))"
  fi
  # 1 MiB of readahead per stream. Several clips then stay sequential.
  src=$(findmnt -n -o SOURCE --mountpoint "$MNT" 2>/dev/null || true)
  [[ -n $src ]] && blockdev --setra 2048 "$src" 2>/dev/null || true
  blockdev --setra 2048 /dev/mapper/dashcam-origin 2>/dev/null || true
  log "share mounted ($fstype, $(findmnt -n -o OPTIONS --mountpoint "$MNT" 2>/dev/null || echo unknown))"
}

# Print, as comments, the settings in the templates that the settings file does
# not mention yet, each with the note written above it. A line that is already
# commented out counts as mentioned, so a rerun adds nothing and an option you
# removed on purpose stays removed.
env_missing_options() {
  awk '
    FNR == 1 { note = "" }
    FILENAME == ARGV[1] {
      line = $0
      sub(/^[ \t]*/, "", line)
      sub(/^#[ \t]*/, "", line)
      sub(/^export[ \t]+/, "", line)
      if (line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        sub(/=.*/, "", line)
        seen[line] = 1
      }
      next
    }
    /^[ \t]*$/ { note = ""; next }
    /^#/ { note = note $0 "\n"; next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key = $0
      sub(/=.*/, "", key)
      if (!(key in seen)) {
        printf "%s# %s\n", note, $0
        seen[key] = 1
      }
      note = ""
    }
  ' "$@"
}

# Add new options to the settings file as comments. Being comments, they cannot
# change what the Pi does, and no value that is already there is touched.
merge_env_options() {
  local added template tmp="${ENV_FILE}.new"
  local -a templates=()
  for template in "$@"; do
    [[ ! -f $template ]] || templates+=("$template")
  done
  ((${#templates[@]})) || return 0
  added=$(env_missing_options "$ENV_FILE" "${templates[@]}")
  [[ -n $added ]] || return 0
  cp -p "$ENV_FILE" "${ENV_FILE}.bak"
  chmod 600 "${ENV_FILE}.bak"
  (
    umask 077
    {
      cat "$ENV_FILE"
      printf '\n# Added by provision. These are new options, shown at their defaults.\n'
      printf '# Remove the # in front of a setting to change it.\n\n'
      printf '%s\n' "$added"
    } >"$tmp"
  )
  mv "$tmp" "$ENV_FILE"
  log "added $(grep -c '^# [A-Za-z_][A-Za-z0-9_]*=' <<<"$added") new options to $ENV_FILE as comments (backup: ${ENV_FILE}.bak)"
}

# Filter the config.txt fragment on stdin. These lines sit inside the managed
# block, so setting REDUCED_POWER back to 0 removes them on the next provision.
# Neither limit slows the car, which is capped by its USB 2 link.
boot_fragment() {
  local reduced=$1
  awk -v reduced="$reduced" '
    /^# END dashcam-bridge$/ && reduced == 1 {
      print "# REDUCED_POWER=1 lowers the peak current of a Pi 5."
      print "[pi5]"
      print "arm_freq=1500"
      print "dtparam=pciex1_gen=1"
      print "[all]"
    }
    {print}
  '
}

# Filter config.txt on stdin. The Pi has no camera or display to look for, and
# the firmware should not spend boot time probing for them.
boot_config_tuned() {
  sed -E 's/^(camera_auto_detect|display_auto_detect)=1$/\1=0/'
}

# Filter a Pi 5 bootloader config on stdin. Every start in the car is a cold
# boot, so drop the network-install screen and skip power negotiation. The new
# line stays in the [all] part, ahead of any conditional section.
eeprom_boot_tuned() {
  local psu_max_current=$1
  awk -v psu="PSU_MAX_CURRENT=${psu_max_current}" '
    /^NET_INSTALL_AT_POWER_ON=/ || /^PSU_MAX_CURRENT=/ {next}
    /^\[/ && $0 != "[all]" && !done {print psu; done=1}
    {print}
    END {if (!done) print psu}
  '
}

# Run a step that must not stop the car's drive, and report it if it fails.
storage_try() {
  local message=$1 rc
  shift
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  if ((rc != 0)); then
    warn "$message"
  fi
}

# The last step before the USB drive goes to the car. Live mode has to mount
# here, because replaying the journal or repairing the filesystem is only safe
# before the car can write. Snapshot mode mounts its own copy-on-write view,
# so share-up.sh does that later and the car does not wait for it.
storage_finish() {
  [[ $SHARE == live ]] || return 0
  storage_try "the share is not mounted, but the USB drive will still come up for the car" mount_share
}

live_refresh() {
  # The car writes underneath this mount, so the kernel's cached directory
  # entries go stale. Dropping them (2 = dentries and inodes) shows new files.
  # Skip it while a client is connected, so its reads stay cached.
  if smb_busy; then
    return 0
  fi
  echo 2 >/proc/sys/vm/drop_caches 2>/dev/null || true
}

refresh_snapshot() {
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
  # The car's writes block while the origin is suspended, so every way out has
  # to resume it. An EXIT trap, because set -e does not run a RETURN trap.
  trap 'dmsetup resume dashcam-origin || true' EXIT
  # The snapshot can be missing if an earlier refresh failed partway through.
  if dmsetup info dashcam-snap >/dev/null 2>&1; then
    dmsetup remove dashcam-snap
  fi
  dd if=/dev/zero of="$COW_LOOP" bs=1M count=4 conv=notrunc status=none
  dmsetup create dashcam-snap --table "0 $(blockdev --getsz "$ORIGIN_LOOP") snapshot ${ORIGIN_LOOP} ${COW_LOOP} N ${SNAP_CHUNK}"
  dmsetup resume dashcam-origin
  trap - EXIT
  udevadm settle || true
  mount_share
}
