#!/bin/bash
# Install dashcam-bridge onto Raspberry Pi OS Lite.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=storage-disk.sh
source "$(dirname "${BASH_SOURCE[0]}")/storage-disk.sh"
require_root

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=/usr/local/lib/dashcam-bridge

model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
[[ -n $model ]] || die "provision.sh runs on the Pi, after Raspberry Pi OS is booted"
log "board: $model"
case "$model" in
*"Pi 5"* | *"Pi 4"* | *"Compute Module 4"* | *"Compute Module 5"*) ;;
*"Zero 2"* | *"Zero"*)
  log "warning: this board's Wi-Fi is 2.4 GHz only, so full-size copies are slow"
  ;;
*)
  die "this board has no USB device port that can face the car. See docs/hardware.md"
  ;;
esac

if [[ ! -f /etc/dashcam-bridge.env ]]; then
  # Validate the repo copy first, so a placeholder password never gets installed.
  ENV_FILE="$REPO/config/dashcam-bridge.env"
  load_env
  install -m 600 "$REPO/config/dashcam-bridge.env" /etc/dashcam-bridge.env
  ENV_FILE=/etc/dashcam-bridge.env
  log "installed /etc/dashcam-bridge.env"
else
  load_env
fi

if ! ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
  alt=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}' || true)
  if [[ -n $alt ]]; then
    log "WIFI_IFACE=$WIFI_IFACE is absent; using $alt"
    sed -i "s/^WIFI_IFACE=.*/WIFI_IFACE=${alt}/" "$ENV_FILE"
    WIFI_IFACE=$alt
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update || die "apt-get update failed. Connect Ethernet or set Wi-Fi in Raspberry Pi Imager, then run provision again."
apt-get install -y \
  samba avahi-daemon exfatprogs dosfstools e2fsprogs kpartx parted \
  wpasupplicant iw rfkill network-manager

if [[ -f /boot/firmware/config.txt ]]; then
  BOOT=/boot/firmware
elif [[ -f /boot/config.txt ]]; then
  BOOT=/boot
else
  die "could not find config.txt under /boot"
fi

boot_changed=0
patch_config() {
  local src=$BOOT/config.txt tmp fragment
  fragment=$REPO/config/boot/config.txt.fragment
  tmp=$(mktemp)
  awk '
    /^# BEGIN dashcam-bridge$/ {skip=1; next}
    /^# END dashcam-bridge$/ {skip=0; next}
    skip {next}
    {print}
  ' "$src" >"$tmp"
  sed -i -E 's/^(otg_mode=1)$/# dashcam-bridge: \1/' "$tmp"
  sed -i -E 's/^(dtoverlay=dwc2.*)$/# dashcam-bridge: \1/' "$tmp"
  boot_config_tuned <"$tmp" >"${tmp}.tuned"
  mv "${tmp}.tuned" "$tmp"
  cat "$fragment" >>"$tmp"
  if ! cmp -s "$tmp" "$src"; then
    [[ -f ${src}.dashcam-bridge.bak ]] || cp -a "$src" "${src}.dashcam-bridge.bak"
    cat "$tmp" >"$src"
    boot_changed=1
    log "updated $src"
  fi
  rm -f "$tmp"
}

patch_cmdline() {
  local src=$BOOT/cmdline.txt line updated
  [[ -f $src ]] || die "missing $src"
  line=$(tr -d '\n' <"$src")
  updated=$line
  if [[ $updated == *"modules-load="* ]]; then
    if [[ $updated != *"modules-load="*"dwc2"* ]]; then
      updated=$(printf '%s\n' "$updated" | sed -E 's/modules-load=([^[:space:]]*)/modules-load=\1,dwc2,libcomposite/')
    fi
  else
    updated="$updated modules-load=dwc2,libcomposite"
  fi
  if [[ $updated != "$line" ]]; then
    [[ -f ${src}.dashcam-bridge.bak ]] || cp -a "$src" "${src}.dashcam-bridge.bak"
    printf '%s\n' "$updated" >"$src"
    boot_changed=1
    log "updated $src"
  fi
}

# A bootloader problem must not fail the install, and this never forces a
# downgrade. The Pi works the same without these settings, just a little slower.
patch_eeprom() {
  local current updated tmp psu=3000
  [[ $model == *"Raspberry Pi 5 "* ]] || return 0
  [[ $POWER_SOURCE == bus ]] || psu=5000
  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    warn "rpi-eeprom-config is missing, so the bootloader boot settings were skipped"
    return 0
  fi
  if ! current=$(rpi-eeprom-config 2>/dev/null) || [[ $current != *BOOT_ORDER=* ]]; then
    warn "could not read the bootloader config, so its boot settings were skipped"
    return 0
  fi
  updated=$(eeprom_boot_tuned "$psu" <<<"$current")
  [[ $updated != "$current" ]] || return 0
  tmp=$(mktemp)
  printf '%s\n' "$updated" >"$tmp"
  if rpi-eeprom-config --apply "$tmp"; then
    boot_changed=1
    log "updated the bootloader boot settings"
  else
    warn "the bootloader settings were not applied. If it refused a downgrade, upgrade the rpi-eeprom package and run provision again."
  fi
  rm -f "$tmp"
}

patch_config
patch_cmdline
patch_eeprom

hostnamectl set-hostname dashcam
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tdashcam/' /etc/hosts
else
  printf '127.0.1.1\tdashcam\n' >>/etc/hosts
fi
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country "${WIFI_COUNTRY^^}" || die "could not set Wi-Fi country ${WIFI_COUNTRY}"
fi
systemctl disable --now bluetooth.service >/dev/null 2>&1 || true

install -d -m 755 "$LIB" /mnt/dashcam "$IMAGE_DIR" /etc/avahi/services /etc/NetworkManager/conf.d
install -m 755 "$REPO"/scripts/*.sh "$LIB/"
install -m 644 "$REPO"/systemd/*.service "$REPO"/systemd/*.timer /etc/systemd/system/
install -m 644 "$REPO/config/avahi-dashcam.service" /etc/avahi/services/dashcam.service
cat >/etc/NetworkManager/conf.d/dashcam-wifi.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

if [[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.pre-dashcam ]]; then
  cp -a /etc/samba/smb.conf /etc/samba/smb.conf.pre-dashcam
fi
share_read_only=no
inbox_available=no
if [[ $SHARE == snapshot ]]; then
  share_read_only=yes
  ((INBOX_GB == 0)) || inbox_available=yes
fi
sed -e "s/__SMB_USER__/${SMB_USER}/g" \
  -e "s/__SHARE_READ_ONLY__/${share_read_only}/g" \
  -e "s/__INBOX_AVAILABLE__/${inbox_available}/g" \
  "$REPO/config/smb.conf" >/etc/samba/smb.conf
testparm -s /etc/samba/smb.conf >/dev/null

if ! id "$SMB_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /usr/sbin/nologin "$SMB_USER"
fi
# Lock only the share account. The Imager user is often named dashcam too,
# and locking that password would shut off SSH.
shell=$(getent passwd "$SMB_USER" | awk -F: '{print $NF}')
case $shell in
  */nologin | */false) passwd -l "$SMB_USER" >/dev/null || true ;;
esac
if pdbedit -L | awk -F: '{print $1}' | grep -qx "$SMB_USER"; then
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s "$SMB_USER"
else
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$SMB_USER"
fi

psk_hex() {
  local ssid=$1 pass=$2 hex
  hex=$(wpa_passphrase "$ssid" "$pass" | awk -F= '/^[[:space:]]*psk=/ {print $2; exit}')
  [[ $hex =~ ^[0-9a-fA-F]{64}$ ]] || die "could not hash a Wi-Fi password"
  printf '%s' "$hex"
}

# Keep a profile's UUID, so a rerun edits it in place. Deleting a profile would
# drop the network that an SSH session running this script may be using.
profile_uuid() {
  local path=$1 uuid
  uuid=$(awk -F= '$1 == "uuid" {print $2; exit}' "$path" 2>/dev/null || true)
  [[ -n $uuid ]] || uuid=$(cat /proc/sys/kernel/random/uuid)
  printf '%s' "$uuid"
}

# NetworkManager profiles are GLib key files, where a backslash is an escape.
keyfile_value() {
  printf '%s' "${1//\\/\\\\}"
}

write_ap() {
  local hex uuid path
  hex=$(psk_hex "$AP_SSID" "$AP_PSK")
  path=/etc/NetworkManager/system-connections/dashcam-ap.nmconnection
  uuid=$(profile_uuid "$path")
  cat >"$path" <<EOF
[connection]
id=dashcam-ap
uuid=${uuid}
type=wifi
interface-name=${WIFI_IFACE}
autoconnect=false

[wifi]
mode=ap
ssid=$(keyfile_value "$AP_SSID")
band=a
channel=36
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=${hex}

[ipv4]
method=shared
address1=192.168.4.1/24

[ipv6]
method=disabled
EOF
  chmod 600 "$path"
}

write_client_networks() {
  local i hex uuid path name old
  nmcli connection delete dashcam-home >/dev/null 2>&1 || true
  rm -f /etc/NetworkManager/system-connections/dashcam-home.nmconnection
  shopt -s nullglob
  for old in /etc/NetworkManager/system-connections/dashcam-net-*.nmconnection; do
    name=$(basename "$old" .nmconnection)
    # Only remove slots that are no longer configured.
    [[ " ${NET_CON[*]:-} " != *" $name "* ]] || continue
    nmcli connection delete "$name" >/dev/null 2>&1 || true
    rm -f "$old"
  done
  shopt -u nullglob
  for i in "${!NET_SSID[@]}"; do
    hex=$(psk_hex "${NET_SSID[$i]}" "${NET_PSK[$i]}")
    name=${NET_CON[$i]}
    path=/etc/NetworkManager/system-connections/${name}.nmconnection
    uuid=$(profile_uuid "$path")
    {
      printf '%s\n' \
        "[connection]" \
        "id=${name}" \
        "uuid=${uuid}" \
        "type=wifi" \
        "interface-name=${WIFI_IFACE}" \
        "autoconnect=false" \
        "autoconnect-priority=${NET_PRI[$i]}" \
        "" \
        "[wifi]" \
        "mode=infrastructure"
      printf 'ssid=%s\n' "$(keyfile_value "${NET_SSID[$i]}")"
      printf '%s\n' \
        "powersave=2" \
        "" \
        "[wifi-security]" \
        "key-mgmt=wpa-psk" \
        "psk=${hex}" \
        "" \
        "[ipv4]" \
        "method=auto" \
        "" \
        "[ipv6]" \
        "method=auto"
    } >"$path"
    chmod 600 "$path"
  done
}

write_ap
write_client_networks
nmcli connection reload

systemctl daemon-reload
systemctl enable smbd nmbd avahi-daemon
systemctl enable dashcam-storage.service dashcam-gadget.service dashcam-share.service
systemctl enable dashcam-refresh.timer dashcam-wifi.timer dashcam-inbox.timer
systemctl restart avahi-daemon || true

if systemctl is-active --quiet dashcam-storage.service || systemctl is-active --quiet dashcam-gadget.service; then
  systemctl stop dashcam-refresh.timer dashcam-inbox.timer dashcam-gadget.service dashcam-storage.service
fi
storage_prepare

log "SMB user ${SMB_USER} can open //dashcam.local/dashcam (SHARE=${SHARE})"
if ((${#NET_SSID[@]})); then
  log "saved networks:"
  for i in "${!NET_SSID[@]}"; do
    log "  ${NET_SSID[$i]} (priority ${NET_PRI[$i]})"
  done
else
  log "no saved networks; the access point is the only Wi-Fi"
fi
log "access point ${AP_SSID} uses 192.168.4.1 when none of those networks are in range"
if ((boot_changed)); then
  log "reboot to apply the boot settings: sudo reboot"
else
  systemctl restart dashcam-storage.service dashcam-gadget.service dashcam-share.service
  systemctl restart dashcam-refresh.timer dashcam-wifi.timer dashcam-inbox.timer
  systemctl start dashcam-wifi.service || true
  log "already provisioned. status: sudo ${LIB}/status.sh"
fi
