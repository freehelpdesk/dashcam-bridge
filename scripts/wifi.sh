#!/bin/bash
# Join the best saved Wi-Fi network, or start the fallback access point.
# A higher priority wins whenever it is on. Equal priorities use the stronger signal.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

quiet_radio() {
  iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
}

ethernet_up() {
  [[ -e /sys/class/net/eth0 ]] && [[ $(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0) == "1" ]]
}

saved_client() {
  local name
  ((${#NET_CON[@]})) || return 1
  for name in "${NET_CON[@]}"; do
    [[ $name == "$1" ]] && return 0
  done
  return 1
}

# Split one `nmcli -t` line. Colons inside a field are escaped as '\:'.
nm_split() {
  local line=$1 i c esc=0 field=""
  NM_FIELDS=()
  for ((i = 0; i < ${#line}; i++)); do
    c=${line:i:1}
    if ((esc)); then
      field+=$c
      esc=0
    elif [[ $c == '\' ]]; then
      esc=1
    elif [[ $c == ':' ]]; then
      NM_FIELDS+=("$field")
      field=""
    else
      field+=$c
    fi
  done
  NM_FIELDS+=("$field")
}

# Scan and rank saved networks that are actually broadcasting.
scan_saved_networks() {
  local raw line ssid sig
  local -a rows=()
  RANK_CON=()
  raw=$(nmcli -t -f SSID,SIGNAL device wifi list ifname "$WIFI_IFACE" --rescan yes 2>/dev/null || true)
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    nm_split "$line"
    ssid=${NM_FIELDS[0]:-}
    sig=${NM_FIELDS[1]:-}
    [[ -n $ssid && $sig =~ ^[0-9]+$ ]] || continue
    rows+=("${ssid}"$'\t'"${sig}")
  done <<< "$raw"
  if ((${#rows[@]} == 0)); then
    return 1
  fi
  rank_saved_networks < <(printf '%s\n' "${rows[@]}")
}

start_ap() {
  nmcli connection modify dashcam-ap wifi.band a wifi.channel 36 || true
  if nmcli --wait 20 connection up dashcam-ap; then
    quiet_radio
    log "access point $AP_SSID is up on 5 GHz"
    return 0
  fi
  nmcli connection modify dashcam-ap wifi.band bg wifi.channel 6
  nmcli --wait 20 connection up dashcam-ap
  quiet_radio
  log "access point $AP_SSID is up on 2.4 GHz"
}

# True when the active link is the only saved network at the top priority.
# A scan cannot outrank it, and a scan blips the association.
on_unique_top() {
  local i max_pri top_count=0 on_top=0
  ((${#NET_PRI[@]})) || return 1
  saved_client "$active" || return 1
  max_pri=${NET_PRI[0]}
  for i in "${!NET_PRI[@]}"; do
    if ((NET_PRI[i] > max_pri)); then
      max_pri=${NET_PRI[i]}
    fi
  done
  for i in "${!NET_PRI[@]}"; do
    if ((NET_PRI[i] == max_pri)); then
      top_count=$((top_count + 1))
      if [[ ${NET_CON[$i]} == "$active" ]]; then
        on_top=1
      fi
    fi
  done
  ((on_top == 1 && top_count == 1))
}

# Fill TRY_* with saved profiles to join, best first.
# WIFI_STAY=1 means the current association should remain if every attempt fails.
# A saved network the scan missed keeps its priority and counts as a full signal,
# so an equal or lower network cannot replace a link the scan failed to list.
plan_wifi_switch() {
  local i
  local active_pri="" active_sig="" active_seen=0
  TRY_CON=()
  TRY_SSID=()
  TRY_PRI=()
  TRY_SIG=()
  WIFI_STAY=0
  for i in "${!RANK_CON[@]}"; do
    if [[ ${RANK_CON[$i]} == "$active" ]]; then
      active_pri=${RANK_PRI[$i]}
      active_sig=${RANK_SIG[$i]}
      active_seen=1
    fi
  done
  if ((active_seen == 0)) && saved_client "$active"; then
    for i in "${!NET_CON[@]}"; do
      if [[ ${NET_CON[$i]} == "$active" ]]; then
        active_pri=${NET_PRI[$i]}
        active_sig=100
      fi
    done
  fi
  for i in "${!RANK_CON[@]}"; do
    if [[ $active == "${RANK_CON[$i]}" ]]; then
      WIFI_STAY=1
      return 0
    fi
    # Same priority: switch only when the other signal leads by 10 points,
    # so two loud networks do not trade places every check.
    if [[ -n $active_pri ]] && ((RANK_PRI[i] == active_pri && RANK_SIG[i] < active_sig + 10)); then
      continue
    fi
    if [[ -n $active_pri ]] && ((RANK_PRI[i] < active_pri)); then
      continue
    fi
    TRY_CON+=("${RANK_CON[$i]}")
    TRY_SSID+=("${RANK_SSID[$i]}")
    TRY_PRI+=("${RANK_PRI[$i]}")
    TRY_SIG+=("${RANK_SIG[$i]}")
  done
  if saved_client "$active"; then
    WIFI_STAY=1
  fi
}

# Sourced by the syntax test. A normal run is not sourced, so `return` fails and we continue.
if [[ ${DASHCAM_TEST:-} == 1 ]]; then
  return 0 2>/dev/null || true
fi

require_root
load_env
mkdir -p "$STATE_DIR"
exec 8>"$STATE_DIR/wifi.lock"
flock -n 8 || exit 0

rfkill unblock wifi || true

active=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v iface="$WIFI_IFACE" '$2 == iface {print $1; exit}' || true)
active=${active:-}

if on_unique_top; then
  quiet_radio
  exit 0
fi

hold=0
if smb_busy; then
  hold=1
fi
if [[ $active == "dashcam-ap" ]]; then
  stations=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null | grep -c '^Station' || true)
  if [[ ${stations:-0} -gt 0 ]]; then
    hold=1
  fi
fi
if ((hold)) && [[ -n $active ]]; then
  log "leaving $active up while a client is connected"
  exit 0
fi

if ((${#NET_SSID[@]})) && scan_saved_networks; then
  plan_wifi_switch
  if ((${#TRY_CON[@]})); then
    for i in "${!TRY_CON[@]}"; do
      if nmcli --wait 25 connection up "${TRY_CON[$i]}"; then
        quiet_radio
        log "joined ${TRY_SSID[$i]} (priority ${TRY_PRI[$i]}, signal ${TRY_SIG[$i]})"
        exit 0
      fi
      log "could not join ${TRY_SSID[$i]}"
    done
    # Trying another network dropped this one, and saved profiles do not
    # autoconnect. Without this the Pi is offline until the next check.
    if ((WIFI_STAY)) && ! nmcli --wait 25 connection up "$active"; then
      log "could not rejoin $active"
      WIFI_STAY=0
      active=""
    fi
  fi
  if ((WIFI_STAY)); then
    quiet_radio
    exit 0
  fi
elif saved_client "$active"; then
  # The scan saw nothing, but the current association is still a saved network.
  quiet_radio
  exit 0
fi

if ethernet_up; then
  log "ethernet is up"
  exit 0
fi

# Either the access point is already up, or the Pi is on a working network this
# script did not set up, such as the Wi-Fi entered in Raspberry Pi Imager.
# Replacing that with the access point would cut off an SSH session.
if [[ -n $active ]]; then
  exit 0
fi

start_ap
