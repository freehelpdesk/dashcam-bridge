#!/bin/bash
# With REDUCED_POWER=1, hold each NVMe drive to its lowest-power working state.
# A drive forgets this when it loses power, so it runs on every boot.
# Nothing here can stop the boot. A drive left at full power still works.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Read `nvme id-ctrl` on stdin and print "state watts" for the operational
# state with the lowest maximum power. A maximum of 0 means "not reported".
nvme_lowest_power_state() {
  awk '
    $1 == "ps" && $4 ~ /^mp:/ && $5 == "operational" {
      watts = $4
      sub(/^mp:/, "", watts)
      sub(/W$/, "", watts)
      if (watts + 0 > 0 && (!found || watts + 0 < best + 0)) {
        found = 1
        best = watts
        state = $2
      }
    }
    END {if (found) print state, best}
  '
}

nvme_limit_one() {
  local dev=$1 output lowest state watts
  if ! output=$(nvme id-ctrl "$dev"); then
    warn "could not read the power states of $dev, so it stays at full power"
    return 0
  fi
  lowest=$(nvme_lowest_power_state <<<"$output")
  if [[ -z $lowest ]]; then
    warn "$dev reports no usable power states, so it stays at full power"
    return 0
  fi
  read -r state watts <<<"$lowest"
  if [[ $state == 0 ]]; then
    notice "$dev has no lower-power working state"
    return 0
  fi
  if nvme set-feature "$dev" --feature-id=2 --value="$state" >/dev/null; then
    notice "$dev limited to power state $state (${watts} W maximum)"
  else
    warn "could not limit $dev, so it stays at full power"
  fi
}

nvme_limit_power() {
  local ctrl
  local -a ctrls=()
  ((REDUCED_POWER)) || return 0
  shopt -s nullglob
  ctrls=("${NVME_CLASS:-/sys/class/nvme}"/nvme*)
  shopt -u nullglob
  ((${#ctrls[@]})) || return 0
  if ! command -v nvme >/dev/null 2>&1; then
    warn "nvme-cli is missing, so the NVMe drive stays at full power. Run provision again."
    return 0
  fi
  for ctrl in "${ctrls[@]}"; do
    nvme_limit_one "/dev/${ctrl##*/}"
  done
}

# Sourced by the tests. A normal run is not sourced, so `return` fails and we continue.
if [[ ${DASHCAM_TEST:-} == 1 ]]; then
  return 0 2>/dev/null || true
fi

require_root
load_env
nvme_limit_power
