#!/usr/bin/env bash
# Push this working tree to the Pi and apply it. Run this on the Mac.
#
#   tools/push-to-pi.sh               test, copy, and run provision
#   tools/push-to-pi.sh --sync-only   copy, and leave the running system alone
#   tools/push-to-pi.sh --reboot      also reboot, if provision says to
#   tools/push-to-pi.sh --force       go ahead even while the car is writing
#   tools/push-to-pi.sh --skip-tests  do not run tests/run.sh first
#   tools/push-to-pi.sh --dry-run     list what would be sent, and stop
#   tools/push-to-pi.sh --host user@host --dir name
#
# DASHCAM_PI sets the default host. Settings stay in /etc/dashcam-bridge.env on
# the Pi, and pushing never replaces them. This has to run on macOS bash 3.2.
set -euo pipefail

HOST=${DASHCAM_PI:-dashcam@dashcam.local}
DIR=dashcam-bridge
SYNC_ONLY=0
REBOOT=0
FORCE=0
SKIP_TESTS=0
DRY_RUN=0
REBOOT_WAIT=${PUSH_REBOOT_WAIT:-15}
POLL_SECS=${PUSH_POLL_SECS:-3}
LOG=.dashcam-bridge-push.log
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'push-to-pi: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case $1 in
    --sync-only) SYNC_ONLY=1 ;;
    --reboot) REBOOT=1 ;;
    --force) FORCE=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --host)
      (($# >= 2)) || die "--host needs a value"
      HOST=$2
      shift
      ;;
    --dir)
      (($# >= 2)) || die "--dir needs a value"
      DIR=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# Both end up inside remote shell commands.
[[ $DIR =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--dir must be a simple folder name in the Pi's home"
[[ $HOST =~ ^[A-Za-z0-9_][A-Za-z0-9._@:-]*$ ]] || die "--host must look like user@host"

# A short path, because macOS limits the length of the SSH control socket.
WORK=$(mktemp -d /tmp/dcpush.XXXXXX)
SSH=(ssh -o ControlMaster=auto -o "ControlPath=$WORK/c" -o ControlPersist=120 -o ConnectTimeout=10)

close_connection() {
  "${SSH[@]}" -O exit "$HOST" >/dev/null 2>&1 || true
}

cleanup() {
  close_connection
  rm -rf "$WORK"
}
trap cleanup EXIT

find_test_bash() {
  local candidate
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash bash; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c '((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))' 2>/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

run_tests() {
  local shell output
  if ! shell=$(find_test_bash); then
    say "skipping the tests: they need bash 4.4 or later (brew install bash)"
    return 0
  fi
  say "running the tests"
  if ! output=$("$shell" "$REPO/tests/run.sh" 2>&1); then
    printf '%s\n' "$output" >&2
    die "the tests failed, so nothing was sent. --skip-tests overrides this."
  fi
  say "${output##*$'\n'}"
}

# Tracked and new files, so uncommitted work goes too and ignored files do not.
# Writes a NUL-separated list and prints how many files are on it.
build_list() {
  local skip_env=$1 file count=0
  command -v git >/dev/null 2>&1 || die "git is required"
  while IFS= read -r -d '' file; do
    case $file in
      .claude/* | */.DS_Store | .DS_Store | */__pycache__/* | __pycache__/*) continue ;;
    esac
    if [[ $skip_env == 1 && $file == config/dashcam-bridge.env ]]; then
      continue
    fi
    [[ -f $REPO/$file ]] || continue # Deleted, but not committed yet.
    printf '%s\0' "$file" >>"$WORK/files"
    count=$((count + 1))
  done < <(git -C "$REPO" ls-files -co --exclude-standard -z)
  ((count > 0)) || die "found no files to send"
  [[ -f $REPO/scripts/provision.sh ]] || die "this does not look like the dashcam-bridge repo"
  printf '%s' "$count"
}

# Read-only. Prints: provisioned=0|1 busy=0|1 usb=<state>
preflight() {
  "${SSH[@]}" "$HOST" bash -s -- preflight <<'REMOTE'
provisioned=0
[ -f /etc/dashcam-bridge.env ] && provisioned=1
busy=0
state=$(cat /sys/class/udc/*/state 2>/dev/null | head -n 1)
if [ "$state" = configured ] && [ -e /dev/mapper/dashcam-origin ]; then
  # Six seconds, because the kernel writes cached data out about every five.
  device=$(basename "$(readlink -f /dev/mapper/dashcam-origin)")
  before=$(awk '{print $7}' "/sys/block/$device/stat")
  sleep 6
  after=$(awk '{print $7}' "/sys/block/$device/stat")
  [ "$before" = "$after" ] || busy=1
fi
echo "provisioned=$provisioned busy=$busy usb=${state:-none}"
REMOTE
}

upload() {
  COPYFILE_DISABLE=1 tar -czf - -C "$REPO" --null -T "$WORK/files" | "${SSH[@]}" "$HOST" \
    "rm -rf ~/$DIR.incoming && mkdir -p ~/$DIR.incoming && opts= && if tar --version 2>/dev/null | grep -q GNU; then opts=--warning=no-unknown-keyword; fi && tar -xzf - \$opts -C ~/$DIR.incoming" ||
    die "the upload failed. The copy on the Pi was not changed."
}

# Swap only after every file has arrived, keeping the last version for rollback.
install_copy() {
  local count=$1
  "${SSH[@]}" "$HOST" bash -s -- "$DIR" "$count" <<'REMOTE'
set -eu
dir=$HOME/$1
new=$dir.incoming
old=$dir.previous
have=$(find "$new" -type f | wc -l | tr -d ' ')
if [ "$have" != "$2" ]; then
  echo "expected $2 files and found $have, so the copy on the Pi was not changed" >&2
  rm -rf "$new"
  exit 1
fi
if [ -f "$dir/config/dashcam-bridge.env" ] && [ ! -f "$new/config/dashcam-bridge.env" ]; then
  mkdir -p "$new/config"
  cp -p "$dir/config/dashcam-bridge.env" "$new/config/dashcam-bridge.env"
fi
if [ -e "$dir" ]; then
  rm -rf "$old"
  mv "$dir" "$old"
fi
mv "$new" "$dir"
REMOTE
}

# A provisioned Pi does not get the repo's env file, so provision could never
# learn about new options. This sends the options with anything private blanked.
send_defaults() {
  sed -E 's/^([A-Za-z0-9_]*(_PSK|_PASSWORD|_TOKEN|_WEBHOOK|_WEBHOOK_URL|_SSID)=).*/\1/' "$REPO/config/dashcam-bridge.env" |
    "${SSH[@]}" "$HOST" "mkdir -p ~/$DIR/config && cat > ~/$DIR/config/dashcam-bridge.env.defaults" ||
    die "could not send the list of options"
}

# sudo asks for its password through the terminal. Without one it cannot ask.
terminal_flag() {
  if [[ -t 0 ]]; then
    printf -- '-t'
  else
    printf -- '-T'
  fi
}

sudo_command() {
  if [[ -t 0 ]]; then
    printf 'sudo'
  else
    printf 'sudo -n'
  fi
}

run_provision() {
  say "running provision on the Pi. The USB drive disconnects briefly."
  "${SSH[@]}" "$(terminal_flag)" "$HOST" \
    "bash -c 'set -o pipefail; cd ~/$DIR && $(sudo_command) ./scripts/provision.sh 2>&1 | tee ~/$LOG'" ||
    die "provision failed. The log is ~/$LOG on the Pi, and the last version is ~/$DIR.previous. The USB drive may be down."
}

needs_reboot() {
  "${SSH[@]}" "$HOST" "grep -q 'reboot to apply' ~/$LOG"
}

reboot_and_wait() {
  local _
  say "rebooting the Pi"
  "${SSH[@]}" "$(terminal_flag)" "$HOST" "$(sudo_command) reboot" || true
  close_connection
  sleep "$REBOOT_WAIT"
  for _ in $(seq 1 40); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true >/dev/null 2>&1; then
      return 0
    fi
    sleep "$POLL_SECS"
  done
  die "the Pi did not come back within a few minutes"
}

# The share waits for Wi-Fi, so give a fresh boot some time.
verify() {
  local _ states
  for _ in $(seq 1 20); do
    states=$("${SSH[@]}" "$HOST" "systemctl is-active dashcam-storage dashcam-gadget dashcam-share" 2>/dev/null | tr '\n' ' ') || true
    if [[ $states == "active active active " ]]; then
      say "storage, USB drive, and share are all running"
      return 0
    fi
    sleep "$POLL_SECS"
  done
  die "storage, USB drive, share reported: ${states:-no answer}. Check journalctl on the Pi."
}

main() {
  local state count skip_env=0

  if ((DRY_RUN)); then
    count=$(build_list 1)
    tr '\0' '\n' <"$WORK/files"
    say "$count files would go to $HOST:~/$DIR (the env file is left out on a provisioned Pi)"
    return 0
  fi

  ((SKIP_TESTS)) || run_tests

  say "checking $HOST"
  state=$(preflight) || die "could not reach $HOST"
  case " $state " in
    *" provisioned=1 "*) skip_env=1 ;;
  esac
  if ((!SYNC_ONLY && !FORCE)); then
    case " $state " in
      *" busy=1 "*)
        die "the USB drive is being written to, and provision would disconnect it. Try again once the car is parked, or use --force or --sync-only."
        ;;
    esac
  fi

  count=$(build_list "$skip_env")
  say "sending $count files"
  upload
  install_copy "$count" || die "the copy on the Pi was not changed"
  ((!skip_env)) || send_defaults

  if ((SYNC_ONLY)); then
    say "copied to ~/$DIR on the Pi. Nothing was restarted."
    return 0
  fi

  run_provision
  if needs_reboot; then
    if ((!REBOOT)); then
      say ""
      say "A reboot is needed, and the USB drive stays down until then."
      say "Finish with: ssh $HOST sudo reboot"
      return 0
    fi
    reboot_and_wait
  fi
  verify
  say "update finished"
}

main
