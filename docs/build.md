# Linux image and provision

The build is Raspberry Pi OS Lite plus `scripts/provision.sh`. There is no custom kernel and no extra distribution. The stock kernel already has the USB device controller, the gadget framework, device-mapper snapshots, ext4, and exFAT.

## OS image

Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. As of November 2026 that image is Debian 13 (Trixie). The Bookworm image sits under Legacy in Imager. Prefer the current Lite image. Bookworm also uses NetworkManager and `/boot/firmware`, so the same provision script runs there if you already have a card.

Lite is the right edition. The Pi never needs a desktop. A desktop image spends RAM and boot time on a display the car does not have.

In Imager's OS customisation:

- Hostname `dashcam`
- A sudo user and a password or an SSH key. This user is how you administer the Pi. The SMB account is separate and cannot SSH
- Wi-Fi country, so the access point is allowed to transmit
- SSH on
- Time zone, so the journal matches local time. Clip filenames come from the car. The Pi clock is for logs
- Wireless LAN: leave it blank and use Ethernet for the first boot, or set the house SSID so the first SSH session has a network. Put that same SSID in `WIFI_NET_1_SSID` later

Write the card, boot the Pi on the official power supply, and SSH in.

## What the kernel has to provide

Provision installs Debian packages and writes boot config. There is no kernel build. It checks that the board can do device mode, then enables the overlay below. These modules are already in the Raspberry Pi OS kernel:

| Piece | Module | How it is turned on |
| --- | --- | --- |
| USB device controller on the USB-C port | `dwc2` | `dtoverlay=dwc2,dr_mode=peripheral` in `config.txt`, and `modules-load=dwc2` on the kernel command line |
| Configfs gadget, mass-storage function | `libcomposite`, `usb_f_mass_storage` | loaded by `gadget-up.sh` |
| Frozen view of the live drive | `dm-snapshot` | loaded by `storage-up.sh` |
| The drive the car writes | `ext4` or `exfat` | used to format `cam.img` |

`dr_mode=peripheral` is required on Pi 4 and Pi 5. Those boards do not wire the OTG ID pin, so the controller will not choose device mode on its own. The overlay is `config/boot/config.txt.fragment`. Provision inserts it between `# BEGIN dashcam-bridge` and `# END dashcam-bridge`, and comments out a conflicting `otg_mode=1` or a second `dtoverlay=dwc2` line. On a Compute Module 4 the fragment also sets `otg_mode=0`.

The kernel command line gains `modules-load=dwc2,libcomposite` if those names are not already there. `cmdline.txt` is a single line. Provision keeps the rest of it.

Backups of both files, taken once, are `config.txt.dashcam-bridge.bak` and `cmdline.txt.dashcam-bridge.bak` next to the originals under `/boot/firmware`.

## Packages

Provision installs:

| Package | Role |
| --- | --- |
| `samba` | SMB share on port 445 |
| `avahi-daemon` | `dashcam.local` |
| `exfatprogs`, `dosfstools`, `e2fsprogs` | format and mount ext4, exFAT, or FAT, including a filesystem the car created itself |
| `kpartx`, `parted` | partition the image, then map that partition out of the snapshot |
| `wpasupplicant` | hash the Wi-Fi password into the NetworkManager profile |
| `iw`, `rfkill` | confirm the access point and turn Wi-Fi power save off |
| `network-manager` | already on Raspberry Pi OS Bookworm and Trixie; listed so the dependency is explicit |

Bluetooth is disabled. The Wi-Fi and Bluetooth radios share one chip, and this box only needs Wi-Fi.

## Configure, then provision

On your computer, copy the repo to the Pi and edit the env file before the first successful provision. The first run copies it to `/etc/dashcam-bridge.env` mode `0600`. Later runs keep that copy. Change a live Pi by editing `/etc/dashcam-bridge.env` and running provision again.

```bash
scp -r dashcam-bridge dashcam@dashcam.local:
ssh dashcam@dashcam.local
cd dashcam-bridge
nano config/dashcam-bridge.env
sudo ./scripts/provision.sh
sudo reboot
```

Set these before you run it. Provision refuses the `CHANGEME` placeholders.

| Key | Meaning |
| --- | --- |
| `WIFI_COUNTRY` | Two-letter country. The access point will not start without it |
| `WIFI_NET_1_SSID`, `WIFI_NET_1_PSK`, `WIFI_NET_1_PRIORITY` | First saved network. Use the house, priority `100`, so it wins whenever it is on |
| `WIFI_NET_2_*` … `WIFI_NET_8_*` | More networks, such as the car's Starlink. A lower priority is used only when every higher one is out of range. The same priority on two networks picks the stronger signal. A blank priority is 100, 90, 80, … from slot 1 downward |
| `AP_SSID`, `AP_PSK` | Fallback network the Pi broadcasts. Password, 8 or more characters |
| `SMB_USER`, `SMB_PASSWORD` | Read-only share login. Default user `dashcam` |
| `STORAGE` | `sd` (default) keeps clips on the boot disk. `nvme` uses an internal NVMe. `usb` uses an external USB disk |
| `IMAGE_GB` | Size of the image file the car sees when `STORAGE=sd`. Default 128. Minimum 64. On USB or NVMe the car sees the whole drive |
| `SHARE` | `live` (default) shows new USB files within a couple of seconds. `snapshot` keeps a frozen view for a long copy |
| `COW_GB` | Scratch space for `SHARE=snapshot`. Default 16. Unused when `SHARE=live` |
| `IMAGE_FS` | `ext4` (default) or `exfat` |
| `GADGET_NOFUA` | `0` flushes writes. `1` is faster and can drop the tail of a clip when power dies |
| `POWER_SOURCE` | `bus` for the one-cable Pi 4. `external` when a GPIO supply powers the board |

`POWER_SOURCE=external` changes the USB descriptor to self-powered. It does not move any wires. The wiring is in `docs/hardware.md`.

After reboot the first start of `dashcam-storage.service` creates the drive the car sees. With `STORAGE=sd` that is a sparse `cam.img` on the boot disk, and the free-space check requires the full size so the card cannot fill up halfway through a trip. With `STORAGE=nvme` or `STORAGE=usb` the drive itself is partitioned and the car writes straight to it. The snapshot scratch file still lives on the boot disk.

## What comes up on boot

| Unit | What it does |
| --- | --- |
| `dashcam-storage.service` | Opens the image file or the USB/NVMe disk and mounts it at `/mnt/dashcam` |
| `dashcam-gadget.service` | Exports `/dev/mapper/dashcam-origin` as a USB drive on the USB-C port |
| `dashcam-share.service` | Restarts Samba once the snapshot is mounted |
| `dashcam-refresh.timer` | Every two seconds, drops the cache so `SHARE=live` shows new USB writes. `SHARE=snapshot` still replaces its frozen view about once a minute |
| `dashcam-wifi.timer` | Every two minutes, joins the best saved network that is actually on. Otherwise starts the access point, trying 5 GHz and falling back to 2.4 GHz |

The car writes the disk through the gadget. With `SHARE=live`, Samba reads that same disk. With `SHARE=snapshot`, Samba reads a frozen view so a long copy is not cut while the car keeps writing.

The share definition is `config/smb.conf`. It is read-only, requires the SMB user, and refuses the connection if `/mnt/dashcam` is not mounted. Finder's `.DS_Store` writes are vetoed.

Wi-Fi power save is turned off. With it left on, a Pi in a car drops the SMB session.

## Bench test

Do this before the Pi goes in the car. The official supply and the car cable use the same USB-C port, so the gadget test is "power the Pi from the laptop's USB-C port."

1. Reboot after provision, on the official supply, and confirm SSH still works.
2. Shut the Pi down, move the USB-C plug from the official supply to a data cable into the laptop. The laptop is standing in for the car. It powers a Pi 4 and should enumerate a USB disk.
3. If the laptop offers to initialize, erase, or format that disk, decline. A format from the laptop replaces the filesystem the car expects.
4. `diskutil list` on a Mac should show a new external disk. macOS will not mount the ext4 volume. The disk showing up is the pass.
5. SSH back in over Ethernet, or over a saved Wi-Fi network if one is in range. The laptop's USB connection is the gadget. SSH and SMB use Ethernet or Wi-Fi.
6. Run `sudo /usr/local/lib/dashcam-bridge/status.sh`. Expect a UDC state, `gadget:` bound to a controller name, the share mounted, and `throttled=0x0`.
7. In Finder, Go → Connect to Server → `smb://dashcam.local/dashcam`. Log in as `dashcam`. `TeslaCam` should be there, with `RecentClips`, `SavedClips`, and `SentryClips` empty.

A Pi 5 powered from a laptop port may log undervoltage during this test. The disk should still enumerate. Give it the separate 5 V supply before it lives in the car.

`status.sh` is the health check after any later change:

```bash
sudo /usr/local/lib/dashcam-bridge/status.sh
sudo journalctl -u dashcam-storage -u dashcam-gadget -u dashcam-wifi -b
```
