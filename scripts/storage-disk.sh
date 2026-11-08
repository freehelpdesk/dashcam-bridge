# Mount an internal NVMe or a USB disk for clip storage.
# Sourced by storage-up.sh and provision.sh after load_env.
STORAGE_LABEL=dashcam-data
TESLA_LABEL=TESLA
# Tesla's floor for the drive it writes to. GiB, same unit as IMAGE_GB.
TESLA_MIN_BYTES=$((64 * 1024 * 1024 * 1024))
# Unit separator, not tab: bash read collapses empty tab-separated fields.
STORAGE_FS=$'\x1f'
FSTAB_BEGIN='# BEGIN dashcam-bridge disk'
FSTAB_END='# END dashcam-bridge disk'
FSTAB_BEGIN_OLD='# BEGIN dashcam-bridge nvme'
FSTAB_END_OLD='# END dashcam-bridge nvme'
FSTAB_FILE=${FSTAB_FILE:-/etc/fstab}
# How long to wait for a USB or NVMe disk to appear during boot.
STORAGE_WAIT_SECS=${STORAGE_WAIT_SECS:-30}

storage_bytes_needed() {
  echo $(( (IMAGE_GB + COW_GB + 2) * 1024 * 1024 * 1024 ))
}

storage_prepare() {
  STORAGE_RAW=0
  DATA_DISK=""
  trap storage_cleanup_staging EXIT
  case $STORAGE in
    sd) storage_use_directory ;;
    nvme) storage_use_extra nvme ;;
    usb) storage_use_extra usb ;;
    *) die "STORAGE must be sd, nvme, or usb" ;;
  esac
}

storage_mount_source() {
  findmnt -n -o SOURCE --mountpoint "$IMAGE_DIR" 2>/dev/null || true
}

storage_blkid() {
  local dev=$1 tag=$2 value=""
  if [[ $dev == UUID=* || $dev == PARTUUID=* ]]; then
    value=$(blkid -t "$dev" -o value -s "$tag" 2>/dev/null | head -1 || true)
  else
    value=$(blkid -o value -s "$tag" "$dev" 2>/dev/null | head -1 || true)
  fi
  printf '%s' "$value"
}

storage_mount_is_ours() {
  local src label
  src=$(storage_mount_source)
  [[ -n $src ]] || return 1
  label=$(storage_blkid "$src" LABEL || true)
  [[ $label == "$STORAGE_LABEL" ]]
}

storage_require_idle() {
  if origin_exists; then
    die "stop the dashcam services before changing STORAGE: sudo systemctl stop dashcam-refresh.timer dashcam-gadget.service dashcam-storage.service"
  fi
  if [[ -f $IMAGE ]] && losetup -j "$IMAGE" 2>/dev/null | grep -q .; then
    die "cam.img is still looped; stop dashcam-storage first"
  fi
}

storage_fstab_apply() {
  local block=$1 file=$FSTAB_FILE tmp last
  tmp=$(mktemp)
  if [[ -f $file ]]; then
    awk -v begin="$FSTAB_BEGIN" -v end="$FSTAB_END" \
      -v oldbegin="$FSTAB_BEGIN_OLD" -v oldend="$FSTAB_END_OLD" '
      $0 == begin || $0 == oldbegin {skip=1; next}
      skip && ($0 == end || $0 == oldend) {skip=0; next}
      skip {next}
      {print}
    ' "$file" >"$tmp"
  fi
  if [[ -n $block ]]; then
    if [[ -s $tmp ]]; then
      last=$(tail -c1 "$tmp" | od -An -tu1 | tr -d ' ')
      [[ $last == 10 ]] || printf '\n' >>"$tmp"
    fi
    printf '%s' "$block" >>"$tmp"
  elif [[ ! -f $file ]]; then
    rm -f "$tmp"
    return 0
  fi
  if [[ -f $file ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 0
  fi
  local dest
  dest=$(mktemp "$(dirname "$file")/fstab.XXXXXX")
  cat "$tmp" >"$dest"
  chmod 644 "$dest"
  mv "$dest" "$file"
  rm -f "$tmp"
}

storage_fstab_clear() {
  storage_fstab_apply ""
}

storage_lsblk_line_to_row() {
  local rest=$1 key val c
  local -A f=()
  [[ -n $rest ]] || return 0
  while [[ -n $rest ]]; do
    [[ $rest == *=* ]] || die "unexpected lsblk line"
    key=${rest%%=*}
    rest=${rest#*=}
    [[ $key =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected lsblk key"
    [[ $rest == \"* ]] || die "unexpected lsblk line"
    rest=${rest:1}
    val=""
    c=""
    while [[ -n $rest ]]; do
      c=${rest:0:1}
      rest=${rest:1}
      if [[ $c == '\' ]]; then
        [[ -n $rest ]] || die "unterminated lsblk escape"
        val+=${rest:0:1}
        rest=${rest:1}
      elif [[ $c == '"' ]]; then
        break
      else
        val+=$c
      fi
    done
    [[ -n $rest || $c == '"' ]] || die "unterminated lsblk value"
    [[ $val != *$'\t'* && $val != *$'\x1f'* ]] || die "lsblk field contains a separator"
    f[$key]=$val
    while [[ $rest == [[:space:]]* && -n $rest ]]; do
      rest=${rest:1}
    done
  done
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "${f[NAME]:-}" "${f[TYPE]:-}" "${f[FSTYPE]:-}" "${f[LABEL]:-}" \
    "${f[SIZE]:-0}" "${f[PKNAME]:-}" "${f[TRAN]:-}"
}

storage_sysfs_tran() {
  local name=$1 link
  [[ -e /sys/block/$name ]] || return 0
  link=$(readlink -f "/sys/block/$name" 2>/dev/null || true)
  if [[ $link == *"/usb"* ]]; then
    printf usb
  fi
}

storage_lsblk_rows() {
  local line row name type fstype label size pkname tran
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    row=$(storage_lsblk_line_to_row "$line")
    [[ -n $row ]] || continue
    IFS=$STORAGE_FS read -r name type fstype label size pkname tran <<<"$row"
    if [[ $type == disk && -z $tran ]]; then
      tran=$(storage_sysfs_tran "$name")
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$name" "$type" "$fstype" "$label" "$size" "$pkname" "$tran"
  done < <(lsblk -b -P -o NAME,TYPE,FSTYPE,LABEL,SIZE,PKNAME,TRAN)
}

storage_root_names() {
  local src dev pk
  ROOT_PART=""
  ROOT_DISK=""
  src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  [[ -n $src ]] || return 0
  if [[ $src == UUID=* || $src == PARTUUID=* ]]; then
    dev=$(blkid -t "$src" -o device 2>/dev/null | awk 'NR==1 {print $1}')
  else
    dev=$src
  fi
  [[ -n $dev && -e $dev ]] || return 0
  dev=$(readlink -f "$dev")
  ROOT_PART=$(basename "$dev")
  while true; do
    pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ -n $pk ]] || break
    if [[ $pk =~ ^(nvme[0-9]+n[0-9]+p[0-9]+|mmcblk[0-9]+p[0-9]+|sd[a-z]+[0-9]+)$ ]]; then
      ROOT_PART=$pk
    fi
    dev=/dev/$pk
  done
  ROOT_DISK=$(basename "$dev")
}

classify_load() {
  local name type fstype label size pkname tran
  declare -gA D_TRAN=() D_SIZE=() D_FSTYPE=() D_LABEL=()
  declare -gA P_DISK=() P_FSTYPE=() P_LABEL=() P_SIZE=()
  declare -ga D_NAMES=() P_NAMES=()
  while IFS=$STORAGE_FS read -r name type fstype label size pkname tran || [[ -n ${name:-} ]]; do
    [[ -n ${name:-} ]] || continue
    if [[ $type == disk ]]; then
      D_NAMES+=("$name")
      D_TRAN[$name]=$tran
      D_SIZE[$name]=${size:-0}
      D_FSTYPE[$name]=$fstype
      D_LABEL[$name]=$label
    elif [[ $type == part ]]; then
      P_NAMES+=("$name")
      P_DISK[$name]=$pkname
      P_FSTYPE[$name]=$fstype
      P_LABEL[$name]=$label
      P_SIZE[$name]=${size:-0}
    fi
  done
}

disk_has_our_label() {
  local disk=$1 p
  [[ ${D_LABEL[$disk]:-} == "$TESLA_LABEL" ]] && return 0
  ((${#P_NAMES[@]})) || return 1
  for p in "${P_NAMES[@]}"; do
    [[ ${P_DISK[$p]} == "$disk" && ${P_LABEL[$p]} == "$TESLA_LABEL" ]] && return 0
  done
  return 1
}

storage_foreign_msg() {
  local disk=$1 detail=$2
  NVME_MODE=refuse
  NVME_DISK=$disk
  NVME_MSG="/dev/${disk} already has data (${detail}). It was left unchanged. Set STORAGE=sd, or adopt the Tesla partition with: e2label /dev/<partition> ${TESLA_LABEL}"
}

classify_boot_disk() {
  local disk=$1 root_part=$2 p found=""
  ((${#P_NAMES[@]})) || P_NAMES=()
  for p in "${P_NAMES[@]+"${P_NAMES[@]}"}"; do
    [[ ${P_DISK[$p]} == "$disk" ]] || continue
    if [[ ${P_LABEL[$p]} == "$TESLA_LABEL" && $p != "$root_part" && -z $found ]]; then
      found=$p
    fi
  done
  NVME_DISK=$disk
  if [[ -n $found ]]; then
    # Only this partition goes to the car. The rest of the disk is the OS.
    NVME_MODE=use_part
    NVME_PART=$found
    NVME_SIZE=${P_SIZE[$found]}
    return 0
  fi
  NVME_MODE=boot
  NVME_PART=$root_part
  NVME_SIZE=${D_SIZE[$disk]:-0}
}

classify_data_disk() {
  local disk=$1 p detail=""
  local -a parts=() labeled=()
  for p in "${P_NAMES[@]+"${P_NAMES[@]}"}"; do
    [[ ${P_DISK[$p]} == "$disk" ]] || continue
    parts+=("$p")
    detail+="${detail:+, }${p} ${P_FSTYPE[$p]:-empty} ${P_LABEL[$p]:-unlabeled}"
    if [[ ${P_LABEL[$p]} == "$TESLA_LABEL" ]]; then
      labeled+=("$p")
    fi
  done
  NVME_DISK=$disk
  NVME_SIZE=${D_SIZE[$disk]:-0}
  NVME_PART=""
  if ((${#labeled[@]} == 1)); then
    NVME_MODE=use
    NVME_PART=${labeled[0]}
    NVME_SIZE=${P_SIZE[${labeled[0]}]}
    return 0
  fi
  if ((${#labeled[@]} > 1)); then
    storage_foreign_msg "$disk" "$detail"
    return 0
  fi
  if ((${#parts[@]} == 0)); then
    if [[ -z ${D_FSTYPE[$disk]} && -z ${D_LABEL[$disk]} ]]; then
      NVME_MODE=format
      return 0
    fi
    if [[ ${D_LABEL[$disk]} == "$TESLA_LABEL" ]]; then
      NVME_MODE=use
      NVME_PART=$disk
      return 0
    fi
    storage_foreign_msg "$disk" "${disk} ${D_FSTYPE[$disk]:-empty} ${D_LABEL[$disk]:-unlabeled}"
    return 0
  fi
  if ((${#parts[@]} == 1)); then
    p=${parts[0]}
    if [[ -z ${P_FSTYPE[$p]} && -z ${P_LABEL[$p]} ]]; then
      NVME_MODE=format_part
      NVME_PART=$p
      NVME_SIZE=${P_SIZE[$p]}
      return 0
    fi
  fi
  storage_foreign_msg "$disk" "$detail"
}

storage_is_kind() {
  local kind=$1 name=$2 tran=$3
  case $kind in
    usb) [[ $tran == usb ]] ;;
    nvme) [[ $tran == nvme || ( -z $tran && $name =~ ^nvme[0-9]+n[0-9]+$ ) ]] ;;
    *) return 1 ;;
  esac
}

storage_kind_title() {
  case $1 in
    usb) printf 'USB disk' ;;
    *) printf 'internal NVMe' ;;
  esac
}

# Read lsblk-style rows: name, type, fstype, label, size, parent, transport.
# kind is nvme or usb. Root disk and root partition are basenames.
# An empty root disk means unknown, and a blank disk is not formatted then.
classify_disk() {
  local kind=$1 root_disk=$2 root_part=$3
  local d title
  local -a chosen=() data=() keep=()
  title=$(storage_kind_title "$kind")
  NVME_MODE=""
  NVME_DISK=""
  NVME_PART=""
  NVME_SIZE=0
  NVME_MSG=""
  classify_load
  if ((${#D_NAMES[@]})); then
    for d in "${D_NAMES[@]}"; do
      storage_is_kind "$kind" "$d" "${D_TRAN[$d]}" || continue
      # A card reader with no card shows up as a disk of size 0.
      if [[ ${D_SIZE[$d]} == 0 ]]; then
        continue
      fi
      chosen+=("$d")
    done
  fi
  if ((${#chosen[@]} == 0)); then
    NVME_MODE=none
    if [[ $kind == usb ]]; then
      NVME_MSG="no USB disk found"
    else
      NVME_MSG="no internal NVMe found"
    fi
    return 0
  fi
  for d in "${chosen[@]}"; do
    [[ $d == "$root_disk" ]] && continue
    data+=("$d")
  done
  if ((${#data[@]} == 0)); then
    classify_boot_disk "$root_disk" "$root_part"
    return 0
  fi
  if ((${#data[@]} > 1)); then
    for d in "${data[@]}"; do
      if disk_has_our_label "$d"; then
        keep+=("$d")
      fi
    done
    if ((${#keep[@]} == 1)); then
      data=("${keep[0]}")
    else
      NVME_MODE=refuse
      NVME_MSG="more than one ${title} (${data[*]}). Label the Tesla partition ${TESLA_LABEL}."
      return 0
    fi
  fi
  classify_data_disk "${data[0]}"
  if [[ -z $root_disk && ( $NVME_MODE == format || $NVME_MODE == format_part ) ]]; then
    NVME_MODE=refuse
    NVME_MSG="could not identify the boot disk, so /dev/${NVME_DISK} was left unchanged."
  fi
}

storage_copy_image() {
  local from=$1 to=$2 need avail src dst
  [[ -f $from/cam.img ]] || return 0
  if [[ -f $to/cam.img ]]; then
    log "cam.img is already on the target disk"
    return 0
  fi
  need=$(storage_bytes_needed)
  avail=$(df -B1 --output=avail "$to" | tail -1 | tr -dc '0-9')
  [[ -n $avail ]] || die "could not read free space on $to"
  if ((avail < need)); then
    die "need $((need / 1024 / 1024 / 1024)) GiB free for the dashcam image, have $((avail / 1024 / 1024 / 1024)) GiB on $to"
  fi
  log "copying cam.img to $to"
  rm -f "$to/cam.img.partial"
  cp --sparse=always -- "$from/cam.img" "$to/cam.img.partial"
  src=$(stat -c %s "$from/cam.img")
  dst=$(stat -c %s "$to/cam.img.partial")
  [[ $src == "$dst" ]] || die "cam.img copy is incomplete"
  sync
  mv -- "$to/cam.img.partial" "$to/cam.img"
}

storage_bind_under() {
  local parent base
  parent=$(dirname "$IMAGE_DIR")
  base=$(basename "$IMAGE_DIR")
  UNDER_MOUNT=/run/dashcam-bridge/parent
  mkdir -p "$UNDER_MOUNT"
  if findmnt -n --mountpoint "$UNDER_MOUNT" >/dev/null; then
    umount "$UNDER_MOUNT" || die "could not unmount $UNDER_MOUNT"
  fi
  mount --bind "$parent" "$UNDER_MOUNT"
  UNDER_DIR=$UNDER_MOUNT/$base
  mkdir -p "$UNDER_DIR"
}

storage_unbind_under() {
  if [[ -n ${UNDER_MOUNT:-} ]] && findmnt -n --mountpoint "$UNDER_MOUNT" >/dev/null 2>&1; then
    umount "$UNDER_MOUNT" || true
  fi
  UNDER_MOUNT=""
}

storage_cleanup_staging() {
  local staging
  storage_unbind_under
  for staging in "${NVME_TMP:-}" /run/dashcam-bridge/disk /run/dashcam-bridge/nvme; do
    [[ -n $staging ]] || continue
    if findmnt -n --mountpoint "$staging" >/dev/null 2>&1; then
      umount "$staging" || true
    fi
  done
}

storage_use_directory() {
  mkdir -p "$IMAGE_DIR"
  if ! storage_mount_is_ours; then
    storage_fstab_clear
    return 0
  fi
  storage_require_idle
  storage_bind_under
  if [[ -f $IMAGE_DIR/cam.img && ! -f $UNDER_DIR/cam.img ]]; then
    storage_copy_image "$IMAGE_DIR" "$UNDER_DIR"
  elif [[ -f $IMAGE_DIR/cam.img && -f $UNDER_DIR/cam.img ]]; then
    log "keeping the cam.img already on the boot disk"
  fi
  umount "$IMAGE_DIR" || die "could not unmount $IMAGE_DIR"
  storage_unbind_under
  storage_fstab_clear
  log "clips stay in $IMAGE_DIR"
}

storage_partition_node() {
  local disk=$1
  case $disk in
    /dev/nvme* | /dev/mmcblk* | /dev/loop*) printf '%s' "${disk}p1" ;;
    *) printf '%s' "${disk}1" ;;
  esac
}

storage_wait_part() {
  local disk=$1 part _ 
  part=$(storage_partition_node "$disk")
  udevadm settle || true
  partx -u "$disk" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    [[ -b $part ]] && break
    sleep 0.1
  done
  [[ -b $part ]] || die "partition $part did not appear"
  printf '%s' "$part"
}

storage_unmount_disk() {
  local disk=/dev/$1 mnt
  [[ -b $disk ]] || return 0
  while read -r mnt; do
    [[ -n $mnt ]] || continue
    umount "$mnt" || die "could not unmount $mnt. $disk is in use."
  done < <(lsblk -ln -o MOUNTPOINT "$disk" 2>/dev/null || true)
}

storage_disk_big_enough() {
  local have=$1
  ((have >= TESLA_MIN_BYTES))
}

# One MBR partition across the target, which is a disk or an image file.
storage_make_tesla_part() {
  local target=$1
  parted -s "$target" mklabel msdos
  if [[ $IMAGE_FS == exfat ]]; then
    parted -s "$target" mkpart primary ntfs 1MiB 100%
  else
    parted -s "$target" mkpart primary ext4 1MiB 100%
  fi
}

# Make the filesystem the car expects, with the folders it looks for.
storage_make_tesla_fs() {
  local part=$1
  if [[ $IMAGE_FS == exfat ]]; then
    mkfs.exfat -n "$TESLA_LABEL" "$part"
  else
    mkfs.ext4 -F -L "$TESLA_LABEL" -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$part"
  fi
  mkdir -p /mnt/dashcam-seed
  mount "$part" /mnt/dashcam-seed
  mkdir -p /mnt/dashcam-seed/TeslaCam/RecentClips
  mkdir -p /mnt/dashcam-seed/TeslaCam/SavedClips
  mkdir -p /mnt/dashcam-seed/TeslaCam/SentryClips
  sync
  umount /mnt/dashcam-seed
  rmdir /mnt/dashcam-seed
}

# Partition the whole device as the drive the car sees. No image file.
storage_format_tesla_disk() {
  local disk=/dev/$1 part title
  title=$(storage_kind_title "${STORAGE_KIND:-nvme}")
  if ! storage_disk_big_enough "$NVME_SIZE"; then
    die "$title $disk has $((NVME_SIZE / 1024 / 1024 / 1024)) GiB. Tesla's floor is 64 GiB."
  fi
  storage_unmount_disk "$1"
  log "formatting $disk as the Tesla drive"
  storage_make_tesla_part "$disk"
  part=$(storage_wait_part "$disk")
  storage_make_tesla_fs "$part"
  storage_unmount_disk "$1"
}

# The hardware identity of a disk. It survives the car reformatting the drive,
# which replaces the label this project otherwise goes by.
storage_disk_id() {
  lsblk -dn -o WWN,SERIAL "/dev/$1" 2>/dev/null | awk '{$1=$1; print; exit}' || true
}

storage_disk_remembered() {
  local id file=$IMAGE_DIR/claimed-disk
  [[ -f $file ]] || return 1
  id=$(storage_disk_id "$1")
  [[ -n $id && $id == "$(cat "$file")" ]]
}

storage_remember_disk() {
  local id
  storage_disk_remembered "$1" && return 0
  id=$(storage_disk_id "$1")
  # Some USB bridges report no identity. Those disks fall back to the label.
  [[ -n $id ]] || return 0
  printf '%s\n' "$id" >"$IMAGE_DIR/claimed-disk"
}

storage_claim_disk() {
  local name=$1
  case $NVME_MODE in
    format | format_part)
      if [[ -n ${D_SIZE[$name]:-} ]]; then
        NVME_SIZE=${D_SIZE[$name]}
      fi
      storage_format_tesla_disk "$name"
      storage_remember_disk "$name"
      ;;
    use)
      storage_unmount_disk "$name"
      storage_remember_disk "$name"
      ;;
    use_part)
      name=$NVME_PART
      storage_unmount_disk "$name"
      ;;
    *) die "internal error: cannot prepare disk mode $NVME_MODE" ;;
  esac
  STORAGE_RAW=1
  DATA_DISK=/dev/$name
  log "$(storage_kind_title "${STORAGE_KIND:-nvme}") $DATA_DISK is the drive the car writes"
}

storage_release_host_mount() {
  mkdir -p "$IMAGE_DIR"
  if storage_mount_is_ours; then
    storage_require_idle
    umount "$IMAGE_DIR" || die "could not unmount $IMAGE_DIR"
  fi
  storage_fstab_clear
}

storage_use_extra() {
  local kind=$1 rows title tries=0
  STORAGE_KIND=$kind
  STORAGE_RAW=0
  DATA_DISK=""
  title=$(storage_kind_title "$kind")
  storage_release_host_mount
  # A USB disk can still be spinning up when this runs at boot.
  while true; do
    udevadm settle >/dev/null 2>&1 || true
    rows=$(storage_lsblk_rows) || die "could not list disks"
    storage_root_names
    classify_disk "$kind" "$ROOT_DISK" "$ROOT_PART" <<<"$rows"
    if [[ $NVME_MODE != none ]] || ((tries >= STORAGE_WAIT_SECS)); then
      break
    fi
    if ((tries == 0)); then
      log "waiting up to ${STORAGE_WAIT_SECS}s for the ${title}"
    fi
    tries=$((tries + 1))
    sleep 1
  done
  # The car may have reformatted the disk this Pi gave it, which drops the
  # TESLA label. That disk is still the car's drive, not someone else's data.
  if [[ $NVME_MODE == refuse && -n $NVME_DISK && -n $ROOT_DISK ]] && storage_disk_remembered "$NVME_DISK"; then
    log "/dev/${NVME_DISK} lost its ${TESLA_LABEL} label but is the disk already in use. Keeping it."
    NVME_MODE=use
  fi
  case $NVME_MODE in
    none)
      if [[ $kind == usb ]]; then
        die "no USB disk found. Set STORAGE=sd, or plug in a USB drive and run provision again."
      fi
      die "no internal NVMe found. Set STORAGE=sd, or install an NVMe drive and run provision again."
      ;;
    refuse)
      die "$NVME_MSG"
      ;;
    boot)
      log "the ${title} is the boot disk, so clips stay in the image file at $IMAGE_DIR"
      ;;
    format|format_part|use|use_part)
      storage_require_idle
      storage_claim_disk "$NVME_DISK"
      ;;
    *)
      die "internal error: bad disk mode ${NVME_MODE:-empty}"
      ;;
  esac
}
