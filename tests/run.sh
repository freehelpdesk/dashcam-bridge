#!/usr/bin/env bash
# Tests for the decision logic. Needs bash 4.4 or later, and no Pi: every
# command that would touch hardware is replaced by a stub.
#
#   bash tests/run.sh
#
# SCRIPTS points the tests at another copy of scripts/.
# shellcheck disable=SC2034  # Variables here are read by the sourced scripts.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "bash 4.4 or later is required (this is $BASH_VERSION)" >&2
  exit 2
fi

SCRIPTS=${SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)}
export DASHCAM_TEST=1
# shellcheck source=../scripts/wifi.sh
source "$SCRIPTS/wifi.sh"
# shellcheck source=../scripts/storage-disk.sh
source "$SCRIPTS/storage-disk.sh"
if [[ -f $SCRIPTS/inbox-apply.sh ]]; then
  # shellcheck source=../scripts/inbox-apply.sh
  source "$SCRIPTS/inbox-apply.sh"
fi
set +e

pass=0
fail=0

check() {
  local name=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
  fi
}

# One lsblk row: name type fstype label size parent transport.
row() {
  local IFS=$'\x1f'
  printf '%s\n' "$*"
}

G64=$((64 * 1024 * 1024 * 1024))
SIZE=$((G64 * 8))

# --- classify_disk ---------------------------------------------------------

classify() { # kind root_disk root_part, rows on stdin
  classify_disk "$1" "$2" "$3"
  printf '%s %s %s' "$NVME_MODE" "$NVME_DISK" "$NVME_PART"
}

SD_ROWS=$(row mmcblk0 disk "" "" "$SIZE" "" ""; row mmcblk0p2 part ext4 rootfs "$SIZE" mmcblk0 "")

result() { # kind root_disk root_part rows; runs in this shell, not a pipeline
  classify "$1" "$2" "$3" <<<"$4"
}

check "blank usb disk is formatted" "format sda " \
  "$(result usb mmcblk0 mmcblk0p2 "$SD_ROWS
$(row sda disk "" "" "$SIZE" "" usb)")"

check "no usb disk" "none  " "$(result usb mmcblk0 mmcblk0p2 "$SD_ROWS")"

check "empty card reader is skipped" "none  " \
  "$(result usb mmcblk0 mmcblk0p2 "$SD_ROWS
$(row sdb disk "" "" 0 "" usb)")"

check "labeled partition is used" "use sda sda1" \
  "$(result usb mmcblk0 mmcblk0p2 "$SD_ROWS
$(row sda disk "" "" "$SIZE" "" usb)
$(row sda1 part ext4 TESLA "$SIZE" sda "")")"

check "foreign data is refused" "refuse sda " \
  "$(result usb mmcblk0 mmcblk0p2 "$SD_ROWS
$(row sda disk "" "" "$SIZE" "" usb)
$(row sda1 part ext4 photos "$SIZE" sda "")")"

check "unknown boot disk never formats" "refuse sda " \
  "$(result usb "" "" "$(row sda disk "" "" "$SIZE" "" usb)")"

check "two labeled disks are refused" "refuse  " \
  "$(result usb mmcblk0 mmcblk0p2 "$SD_ROWS
$(row sda disk "" "" "$SIZE" "" usb)
$(row sda1 part ext4 TESLA "$SIZE" sda "")
$(row sdb disk "" "" "$SIZE" "" usb)
$(row sdb1 part ext4 TESLA "$SIZE" sdb "")")"

NVME_BOOT=$(row nvme0n1 disk "" "" "$SIZE" "" nvme; row nvme0n1p1 part vfat bootfs 1000 nvme0n1 ""; row nvme0n1p2 part ext4 rootfs 1000 nvme0n1 "")

check "boot disk stays in image mode" "boot nvme0n1 nvme0n1p2" \
  "$(result nvme nvme0n1 nvme0n1p2 "$NVME_BOOT")"

check "boot disk gives up only its TESLA partition" "use_part nvme0n1 nvme0n1p3" \
  "$(result nvme nvme0n1 nvme0n1p2 "$NVME_BOOT
$(row nvme0n1p3 part ext4 TESLA "$SIZE" nvme0n1 "")")"

# --- rank_saved_networks ---------------------------------------------------

NET_SSID=(house starlink cafe)
NET_PSK=(aaaaaaaa bbbbbbbb cccccccc)
NET_PRI=(100 10 10)
NET_CON=(c-house c-starlink c-cafe)

ranked() {
  rank_saved_networks < <(printf '%b' "$1")
  printf '%s' "${RANK_SSID[*]:-}"
}

check "priority beats signal" "house starlink" "$(ranked 'starlink\t99\nhouse\t20\n')"
check "equal priority uses signal" "cafe starlink" "$(ranked 'starlink\t30\ncafe\t60\n')"
check "strongest BSSID of an SSID counts" "starlink cafe" "$(ranked 'starlink\t10\ncafe\t50\nstarlink\t70\n')"
check "unsaved networks are ignored" "" "$(ranked 'neighbor\t99\n')"

# --- plan_wifi_switch ------------------------------------------------------

plan() { # active, scan rows
  active=$1
  rank_saved_networks < <(printf '%b' "$2")
  plan_wifi_switch
  printf '%s stay=%s' "${TRY_CON[*]:-none}" "$WIFI_STAY"
}

check "moves up to a higher priority" "c-house stay=1" "$(plan c-starlink 'house\t20\nstarlink\t90\n')"
check "does not move down" "none stay=1" "$(plan c-house 'house\t20\nstarlink\t90\n')"
check "equal priority needs a 10 point lead" "none stay=1" "$(plan c-starlink 'starlink\t50\ncafe\t59\n')"
check "equal priority switches on a clear lead" "c-cafe stay=1" "$(plan c-starlink 'starlink\t50\ncafe\t60\n')"
check "from the access point, try everything" "c-house c-starlink stay=0" "$(plan dashcam-ap 'house\t20\nstarlink\t90\n')"

# --- nm_split --------------------------------------------------------------

nm_split 'my\:net:77'
check "nm_split unescapes colons" "my:net|77" "${NM_FIELDS[0]}|${NM_FIELDS[1]}"

# --- refresh_snapshot: the origin must never stay suspended ----------------

refresh_state() { # dmsetup verb that should fail, or none
  local fail_on=$1 log_file
  log_file=$(mktemp)
  (
    SNAP_CHUNK=32
    load_loops() { ORIGIN_LOOP=/dev/loop0 COW_LOOP=/dev/loop1; }
    findmnt() { return 1; }
    kpartx() { :; }
    udevadm() { :; }
    mount_share() { echo mounted >>"$log_file"; }
    dd() { :; }
    blockdev() { [[ $1 != --getsz ]] || echo 2048; }
    dmsetup() {
      echo "$1" >>"$log_file"
      [[ $1 == "$fail_on" ]] && return 1
      return 0
    }
    set -e
    refresh_snapshot
  ) >/dev/null 2>&1
  awk '
    $0 == "suspend" {s=1}
    $0 == "resume" {s=0}
    $0 == "mounted" {m=1}
    END {print (s ? "suspended" : "resumed") (m ? " mounted" : " unmounted")}
  ' "$log_file"
  rm -f "$log_file"
}

check "refresh resumes and remounts after success" "resumed mounted" "$(refresh_state none)"
check "refresh resumes when remove fails" "resumed unmounted" "$(refresh_state remove)"
check "refresh resumes when create fails" "resumed unmounted" "$(refresh_state create)"

# --- mount_share -----------------------------------------------------------

if declare -F map_first_partition >/dev/null; then
  mount_scenario() { # share mode, filesystem
    local mode=$1 fs=$2 sandbox
    sandbox=$(mktemp -d)
    (
      SHARE=$mode
      MNT=$sandbox/mnt
      mounted=$sandbox/mounted
      map_first_partition() { echo /dev/fake1; }
      findmnt() {
        [[ -f $mounted ]] || return 1
        echo /dev/fake1
      }
      share_is_ro() { return 1; }
      blockdev() { :; }
      blkid() { echo "$fs"; }
      mount() {
        touch "$mounted"
        echo "$*" >>"$sandbox/calls"
      }
      set -e
      mount_share
    ) >/dev/null 2>&1
    echo "rc=$? $(paste -s -d ';' "$sandbox/calls" 2>/dev/null | sed "s|$sandbox|X|g")"
    rm -rf "$sandbox"
  }

  check "snapshot ext4 ends read-only" \
    "rc=0 -t ext4 -o noatime /dev/fake1 X/mnt;-o remount,ro X/mnt" "$(mount_scenario snapshot ext4)"
  check "snapshot exfat mounts read-only" \
    "rc=0 -t exfat -o ro,noatime,umask=022 /dev/fake1 X/mnt" "$(mount_scenario snapshot exfat)"
  check "live ext4 mounts read-write" \
    "rc=0 -t ext4 -o rw,noatime,errors=continue /dev/fake1 X/mnt" "$(mount_scenario live ext4)"
  check "live vfat mounts read-write" \
    "rc=0 -t vfat -o rw,noatime,umask=022 /dev/fake1 X/mnt" "$(mount_scenario live vfat)"
  check "an unknown filesystem is an error" "rc=1 " "$(mount_scenario snapshot ntfs)"
fi

# --- inbox ----------------------------------------------------------------

if declare -F inbox_due >/dev/null; then
  INBOX_IDLE_SECS=120 INBOX_SETTLE_SECS=60 INBOX_MAX_SECS=60

  due() { # now newest car failed
    if inbox_due "$@"; then echo due; else echo wait; fi
  }
  check "inbox goes when settled and car idle" due "$(due 1000 900 800 0)"
  check "inbox waits for the upload to settle" wait "$(due 1000 950 800 0)"
  check "inbox waits while the car writes" wait "$(due 1000 900 900 0)"
  check "inbox does not retry a failure right away" wait "$(due 5000 900 800 4900)"
  check "inbox retries a failure after an hour" due "$(due 9000 900 800 5000)"
  check "something new overrides the retry wait" due "$(due 5000 4920 800 4900)"

  # A real directory tree stands in for the inbox and the drive.
  inbox_sandbox() {
    SANDBOX=$(cd -P "$(mktemp -d)" && pwd)
    INBOX_MNT=$SANDBOX/inbox
    APPLY_MNT=$SANDBOX/drive
    STATE_DIR=$SANDBOX/state
    FAILED_STAMP=$STATE_DIR/inbox-failed
    GADGET_ROOT=$SANDBOX/gadget
    mkdir -p "$INBOX_MNT/Boombox/sub" "$INBOX_MNT/lost+found" "$APPLY_MNT" "$STATE_DIR" "$GADGET_ROOT"
    echo horn >"$INBOX_MNT/Boombox/sub/horn wav.wav"
    echo junk >"$INBOX_MNT/Boombox/sub/._horn wav.wav"
    echo top >"$INBOX_MNT/LockChime.wav"
    echo lost >"$INBOX_MNT/lost+found/ignored"
  }

  # GNU realpath -m is not on every machine that runs these tests.
  realpath() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${@: -1}"
  }

  # Run the whole apply with the hardware stubbed. Prints the order of events,
  # and what is left in the inbox and on the drive.
  apply_scenario() { # what fails: none, mount, or umount
    local fail=$1 events
    inbox_sandbox
    events=$SANDBOX/events
    (
      gadget_detach() { echo detach >>"$events"; }
      gadget_attach() { echo attach >>"$events"; }
      map_first_partition() { echo /dev/fake; }
      kpartx() { :; }
      mounted=$SANDBOX/mounted
      findmnt() { [[ -f $mounted ]]; }
      mount_drive_rw() {
        [[ $fail != mount ]] || return 1
        touch "$mounted"
        echo mount >>"$events"
      }
      umount() {
        [[ $fail != umount ]] || return 1
        rm -f "$mounted"
        echo umount >>"$events"
      }
      sleep() { :; }
      set -e
      mapfile -d '' files < <(inbox_files)
      inbox_apply_now "${files[@]}"
    ) >/dev/null 2>&1
    printf '%s|' "$(tr '\n' ' ' <"$events")"
    printf 'inbox:%s|' "$(cd "$INBOX_MNT" && find . -type f ! -path './lost+found/*' | sort | tr '\n' ' ')"
    printf 'drive:%s' "$(cd "$APPLY_MNT" && find . -type f | sort | tr '\n' ' ')"
    rm -rf "$SANDBOX"
  }

  check "apply detaches, writes, unmounts, then reattaches" \
    "detach mount umount attach |inbox:|drive:./Boombox/sub/horn wav.wav ./LockChime.wav " \
    "$(apply_scenario none)"
  check "a failed mount still gives the car its drive back" \
    "detach attach |inbox:./Boombox/sub/._horn wav.wav ./Boombox/sub/horn wav.wav ./LockChime.wav |drive:" \
    "$(apply_scenario mount)"
  check "a stuck unmount keeps the inbox and never reattaches" \
    "detach mount |inbox:./Boombox/sub/._horn wav.wav ./Boombox/sub/horn wav.wav ./LockChime.wav |drive:./Boombox/sub/horn wav.wav ./LockChime.wav " \
    "$(apply_scenario umount)"

  # Files that cannot be written stay behind, and the good ones still go.
  copy_scenario() {
    inbox_sandbox
    mkdir -p "$INBOX_MNT/escape" "$SANDBOX/outside"
    echo evil >"$INBOX_MNT/escape/owned"
    ln -s "$SANDBOX/outside" "$APPLY_MNT/escape"
    mkdir -p "$APPLY_MNT/LockChime.wav"
    mapfile -d '' files < <(inbox_files)
    inbox_copy_files "${files[@]}" >/dev/null 2>&1
    printf 'applied=%s failed=%s outside=%s' "${#APPLIED[@]}" "$APPLY_FAILED" "$(find "$SANDBOX/outside" -type f | wc -l | tr -d ' ')"
    rm -rf "$SANDBOX"
  }
  check "symlinks and folder clashes are refused" "applied=1 failed=1 outside=0" "$(copy_scenario)"

  time_limit_scenario() {
    inbox_sandbox
    INBOX_MAX_SECS=0
    mapfile -d '' files < <(inbox_files)
    inbox_copy_files "${files[@]}" >/dev/null 2>&1
    printf 'applied=%s failed=%s' "${#APPLIED[@]}" "$APPLY_FAILED"
    rm -rf "$SANDBOX"
  }
  check "the time limit leaves files for later, not failed" "applied=0 failed=0" "$(time_limit_scenario)"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
