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

# common.sh narrows PATH, which can hide the newer Python on a development machine.
PYTHON=$(command -v python3 || true)
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

# --- boot order -------------------------------------------------------------

if [[ -f $SCRIPTS/share-up.sh ]]; then
  # shellcheck source=../scripts/share-up.sh
  source "$SCRIPTS/share-up.sh"
  set +e
  UNITS=$SCRIPTS/../systemd

  # Every step the boot code runs, in order, with an optional failing step.
  boot_steps() { # function to run, share mode, step that fails
    local run=$1 fail=${3:-none}
    (
      SHARE=$2
      lock_wait() { :; }
      origin_exists() { return 0; }
      mount_share() {
        echo mount_share
        [[ $fail != mount_share ]]
      }
      inbox_up() { echo inbox_up; }
      warn() { :; }
      set -e
      "$run"
      echo finished
    ) 2>/dev/null | tr '\n' ' '
  }

  check "snapshot mode does not mount before the car connects" "finished " "$(boot_steps storage_finish snapshot)"
  check "live mode mounts before the car connects" "mount_share finished " "$(boot_steps storage_finish live)"
  check "snapshot mounts the share and inbox afterward" "mount_share inbox_up finished " "$(boot_steps share_up snapshot)"
  check "a failed share mount does not stop the inbox" "mount_share inbox_up finished " "$(boot_steps share_up snapshot mount_share)"
  check "live mode never mounts after the car connects" "finished " "$(boot_steps share_up live)"

  for unit in dashcam-storage dashcam-gadget; do
    check "$unit starts in early boot" 1 "$(grep -c '^DefaultDependencies=no$' "$UNITS/$unit.service")"
    check "$unit stops before shutdown" 1 "$(grep -c '^Conflicts=shutdown.target$' "$UNITS/$unit.service")"
    check "$unit does not wait for the share or network" 0 \
      "$(grep -E '^(After|Requires|Wants)=' "$UNITS/$unit.service" | grep -cE 'dashcam-share|smbd|network|basic.target')"
  done
  check "share waits for the car's drive" 1 "$(grep -E '^After=' "$UNITS/dashcam-share.service" | grep -c dashcam-gadget)"
fi

# --- boot tuning -----------------------------------------------------------

if declare -F eeprom_boot_tuned >/dev/null; then
  lines() { # stdin to one line, so a whole config compares in a single check
    paste -s -d '|' -
  }
  check "config.txt detection is turned off" "camera_auto_detect=0|# keep|display_auto_detect=0|xcamera_auto_detect=1" \
    "$(printf 'camera_auto_detect=1\n# keep\ndisplay_auto_detect=1\nxcamera_auto_detect=1\n' | boot_config_tuned | lines)"

  PI_EEPROM='[all]
BOOT_UART=1
BOOT_ORDER=0xf461
NET_INSTALL_AT_POWER_ON=1'
  TUNED_EEPROM=$(eeprom_boot_tuned 3000 <<<"$PI_EEPROM")
  check "eeprom drops the install screen and skips negotiation" \
    "[all]|BOOT_UART=1|BOOT_ORDER=0xf461|PSU_MAX_CURRENT=3000" "$(lines <<<"$TUNED_EEPROM")"
  check "eeprom tuning is stable on a rerun" "$TUNED_EEPROM" "$(eeprom_boot_tuned 3000 <<<"$TUNED_EEPROM")"
  check "eeprom setting replaces an old value" \
    "[all]|BOOT_ORDER=0xf1|PSU_MAX_CURRENT=5000" \
    "$(printf '[all]\nPSU_MAX_CURRENT=3000\nBOOT_ORDER=0xf1\n' | eeprom_boot_tuned 5000 | lines)"
  check "eeprom setting stays out of conditional sections" \
    "[all]|BOOT_ORDER=0xf1|PSU_MAX_CURRENT=3000|[gpio8=0]|BOOT_ORDER=0xf7" \
    "$(printf '[all]\nBOOT_ORDER=0xf1\n[gpio8=0]\nBOOT_ORDER=0xf7\n' | eeprom_boot_tuned 3000 | lines)"
fi

# --- telemetry -------------------------------------------------------------

if [[ -f $SCRIPTS/telemetry.py ]]; then
  telemetry_value() { # extra assignments, then validate
    (
      TELEMETRY=1 TELEMETRY_TOKEN=abcdefghijklmnop1234 TELEMETRY_PORT=8088 TELEMETRY_BIND=0.0.0.0
      TELEMETRY_POLL_SECS=10 TELEMETRY_BRAKE_MPS2=4 TELEMETRY_ACCEL_MPS2=4 TELEMETRY_CORNER_MPS2=4.5
      TELEMETRY_HOLD_MS=250 TELEMETRY_KEEP_DAYS=30 TELEMETRY_WEBHOOK_URL= TELEMETRY_WEBHOOK_FORMAT=json
      TELEMETRY_WEBHOOK_GPS=0 TELEMETRY_WRITE_LOG=0
      for assignment in "$@"; do
        printf -v "${assignment%%=*}" '%s' "${assignment#*=}"
      done
      validate_telemetry
    ) 2>&1
  }
  telemetry_refused() { # expected text, then assignments
    local want=$1 out
    shift
    out=$(telemetry_value "$@")
    [[ $out == *"$want"* ]] && echo yes
  }
  check "good telemetry settings pass" "" "$(telemetry_value)"
  check "telemetry off needs no token" "" "$(telemetry_value TELEMETRY=0 TELEMETRY_TOKEN=)"
  check "placeholder token is refused" "yes" "$(telemetry_refused TELEMETRY_TOKEN TELEMETRY_TOKEN=CHANGEME)"
  check "short token is refused" "yes" "$(telemetry_refused TELEMETRY_TOKEN TELEMETRY_TOKEN=short)"
  check "token with a space is refused" "yes" "$(telemetry_refused TELEMETRY_TOKEN 'TELEMETRY_TOKEN=abcdefghijkl mnop1234')"
  check "privileged port is refused" "yes" "$(telemetry_refused TELEMETRY_PORT TELEMETRY_PORT=80)"
  check "zero threshold is refused" "yes" "$(telemetry_refused BRAKE TELEMETRY_BRAKE_MPS2=0.0)"
  check "webhook needs http" "yes" "$(telemetry_refused WEBHOOK_URL TELEMETRY_WEBHOOK_URL=ftp://x)"
  check "write log needs telemetry" "yes" "$(telemetry_refused 'needs TELEMETRY' TELEMETRY=0 TELEMETRY_WRITE_LOG=1)"

  UNITS=$SCRIPTS/../systemd
  check "scanner waits for the car's drive" 1 "$(grep -E '^After=' "$UNITS/dashcam-telemetry-scan.service" | grep -c dashcam-gadget)"
  check "nothing the car needs waits for telemetry" 0 \
    "$(grep -hE '^(After|Requires|Wants)=' "$UNITS/dashcam-storage.service" "$UNITS/dashcam-gadget.service" | grep -c telemetry)"
  check "api is not root" 1 "$(grep -c '^User=dashcam-telemetry$' "$UNITS/dashcam-telemetry.service")"
  check "teardown clears a leftover view" 1 "$(grep -c 'dmsetup remove dashcam-telem' "$SCRIPTS/common.sh")"
  check "provision installs the python" 1 "$(grep -c 'scripts/\*.py' "$SCRIPTS/provision.sh")"

  if [[ -n $PYTHON ]]; then
    PY_OUTPUT=$(SCRIPTS=$SCRIPTS "$PYTHON" -I "$SCRIPTS/../tests/test_telemetry.py" 2>&1)
    PY_RC=$?
    check "telemetry unit tests" 0 "$PY_RC"
    ((PY_RC == 0)) || printf '%s\n' "$PY_OUTPUT"
  else
    printf 'skipped the telemetry unit tests: python3 is missing\n'
  fi
fi

# --- reduced power ---------------------------------------------------------

if [[ -f $SCRIPTS/nvme-power.sh ]]; then
  # shellcheck source=../scripts/nvme-power.sh
  source "$SCRIPTS/nvme-power.sh"
  set +e
  FRAGMENT='# BEGIN dashcam-bridge
[all]
dtoverlay=dwc2,dr_mode=peripheral
# END dashcam-bridge'
  check "reduced power off leaves the boot block alone" "$FRAGMENT" "$(boot_fragment 0 <<<"$FRAGMENT")"
  REDUCED_BLOCK=$(boot_fragment 1 <<<"$FRAGMENT")
  check "reduced power limits only a Pi 5, inside the managed block" \
    "[pi5]|arm_freq=1500|dtparam=pciex1_gen=1|[all]|# END dashcam-bridge" \
    "$(tail -n 5 <<<"$REDUCED_BLOCK" | paste -s -d '|' -)"

  ID_CTRL='vid       : 0xc0a9
ps      0 : mp:8.00W operational enlat:0 exlat:0 rrt:0 rrl:0
          rwt:0 rwl:0 idle_power:- active_power:-
ps      1 : mp:4.50W operational enlat:0 exlat:0 rrt:1 rrl:1
ps      2 : mp:3.20W operational enlat:0 exlat:0 rrt:2 rrl:2
ps      3 : mp:0.0500W non-operational enlat:500 exlat:2000 rrt:3 rrl:3
ps      4 : mp:0.0040W non-operational enlat:2000 exlat:40000 rrt:4 rrl:4'
  check "lowest working power state skips sleep states" "2 3.20" "$(nvme_lowest_power_state <<<"$ID_CTRL")"
  check "power compares as a number" "1 0.0900" \
    "$(printf 'ps 0 : mp:10.00W operational\nps 1 : mp:0.0900W operational\nps 2 : mp:9.00W operational\n' | nvme_lowest_power_state)"
  check "power does not compare as text" "0 9.00" \
    "$(printf 'ps 0 : mp:9.00W operational\nps 1 : mp:10.00W operational\n' | nvme_lowest_power_state)"
  check "an unreported maximum is not the lowest" "1 5.00" \
    "$(printf 'ps 0 : mp:0.00W operational\nps 1 : mp:5.00W operational\n' | nvme_lowest_power_state)"
  check "no working states gives no answer" "" \
    "$(printf 'ps 0 : mp:0.05W non-operational\n' | nvme_lowest_power_state)"

  nvme_scenario() { # reduced, controllers, id-ctrl text or "fail", set result
    local sandbox calls=() name
    REDUCED_POWER=$1
    sandbox=$(mktemp -d)
    NVME_CLASS=$sandbox
    for name in $2; do mkdir "$sandbox/$name"; done
    STUB_ID=$3
    STUB_SET=${4:-0}
    nvme() {
      printf '%s\n' "$*" >>"$sandbox/calls"
      case $1 in
        id-ctrl)
          [[ $STUB_ID != fail ]] || return 1
          printf '%s\n' "$STUB_ID"
          ;;
        set-feature) return "$STUB_SET" ;;
      esac
    }
    nvme_limit_power >/dev/null 2>&1
    printf 'rc=%s %s' "$?" "$(grep -h '^set-feature' "$sandbox/calls" 2>/dev/null | paste -s -d '|' -)"
    rm -rf "$sandbox"
  }
  check "reduced power off never touches the drive" "rc=0 " "$(nvme_scenario 0 nvme0 "$ID_CTRL")"
  check "the drive is set to its lowest working state" "rc=0 set-feature /dev/nvme0 --feature-id=2 --value=2" \
    "$(nvme_scenario 1 nvme0 "$ID_CTRL")"
  check "every drive is limited" \
    "rc=0 set-feature /dev/nvme0 --feature-id=2 --value=2|set-feature /dev/nvme1 --feature-id=2 --value=2" \
    "$(nvme_scenario 1 'nvme0 nvme1' "$ID_CTRL")"
  check "no drive is not an error" "rc=0 " "$(nvme_scenario 1 '' "$ID_CTRL")"
  check "a drive with one working state is left alone" "rc=0 " \
    "$(nvme_scenario 1 nvme0 'ps 0 : mp:8.00W operational')"
  check "an unreadable drive does not fail the boot" "rc=0 " "$(nvme_scenario 1 nvme0 fail)"
  check "a refused limit does not fail the boot" "rc=0 set-feature /dev/nvme0 --feature-id=2 --value=2" \
    "$(nvme_scenario 1 nvme0 "$ID_CTRL" 1)"

  missing_tool() {
    local sandbox
    sandbox=$(mktemp -d)
    mkdir "$sandbox/nvme0"
    REDUCED_POWER=1 NVME_CLASS=$sandbox
    unset -f nvme
    PATH=/nonexistent nvme_limit_power 2>&1
    printf 'rc=%s\n' "$?"
    /bin/rm -rf "$sandbox"
  }
  check "missing nvme-cli warns and carries on" \
    "nvme-cli is missing, so the NVMe drive stays at full power. Run provision again.|rc=0" \
    "$(missing_tool | paste -s -d '|' -)"

  reduced_value() {
    WIFI_COUNTRY=US AP_SSID=dashcam AP_PSK=password1 SMB_PASSWORD=password1 SMB_USER=dashcam
    IMAGE_GB=128 COW_GB=16 IMAGE_FS=ext4 STORAGE=sd SHARE=snapshot GADGET_NOFUA=0 POWER_SOURCE=bus
    SNAP_CHUNK=32 INBOX_GB=4 INBOX_IDLE_SECS=120 INBOX_SETTLE_SECS=60 INBOX_MAX_SECS=60
    REDUCED_POWER=$1 TELEMETRY=0 TELEMETRY_WRITE_LOG=0
    (validate_env) 2>&1
  }
  check "reduced power accepts 1" "" "$(reduced_value 1)"
  check "reduced power refuses other values" "REDUCED_POWER must be 0 or 1" "$(reduced_value yes)"

  NVME_UNIT=$SCRIPTS/../systemd/dashcam-nvme-power.service
  check "nvme limit is in place before the car writes" 1 "$(grep -E '^Before=' "$NVME_UNIT" | grep -c dashcam-gadget)"
  check "a failed nvme limit cannot stop the gadget" 0 \
    "$(grep -hE '^(Requires|Requisite|BindsTo)=' "$NVME_UNIT" "$SCRIPTS/../systemd/dashcam-gadget.service" | grep -c 'nvme-power')"
  check "provision enables the nvme limit" 1 "$(grep -c 'enable .*dashcam-nvme-power.service' "$SCRIPTS/provision.sh")"
fi

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
