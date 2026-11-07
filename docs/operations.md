# Using the share

Plug the Pi's USB-C port into the USB port the car already uses for its dashcam drive. On a Tesla that has a glovebox USB port, use that one. Some center-console ports only charge, and a charge-only port will never see the drive.

The car may offer to format the drive the first time. Declining is the right start: the image is already ext4, labeled `TESLA`, with a `TeslaCam` directory. If the car insists, accept the format once. The next snapshot refresh mounts whatever the car wrote, including exFAT. Do the format from the car, not from a laptop.

## Copy clips

The Pi joins the highest-priority saved network that is actually broadcasting. With the house at priority 100 and the car's Starlink at priority 10, the driveway uses the house even when Starlink is the louder of the two. On the road the house is gone, so the Pi joins Starlink. Two networks set to the same priority follow signal strength, and the Pi switches only when the other signal leads by 10 points. Each saved network has to broadcast its name.

On whichever saved network the Pi joined:

```text
smb://dashcam.local/dashcam
```

The laptop has to be on that same network. A copy that is already running keeps the Pi on its current network; pulling into the driveway does not cut it. After the copy finishes, the next check (about two minutes) moves the Pi to the house if the house is on.

On the Pi's own access point, join the `AP_SSID` network (default name `dashcam`) and connect to:

```text
smb://192.168.4.1/dashcam
```

The SMB user is `dashcam` unless you changed `SMB_USER`. The password is `SMB_PASSWORD`. The access-point password is `AP_PSK`. They are different.

| Folder | What it holds |
| --- | --- |
| `TeslaCam/SavedClips` | Clips kept with the save button or a honk |
| `TeslaCam/SentryClips` | Sentry events |
| `TeslaCam/RecentClips` | The rolling recent drive. The car overwrites the oldest as the image fills |

Copy `SavedClips` and `SentryClips` when you want to keep something. `RecentClips` is the last stretch of driving and will age out.

`SHARE=live` is the default, and that share is writable. A file you put there is on the drive the car sees. Eject the USB disk on any computer that had it open before you write, and do not write while the car has that disk open. A file copied onto the USB disk shows up after you disconnect from the share, within a couple of seconds. While a copy or playback is running, the Pi keeps the files cached so several clips can load together. Play them from the house Wi-Fi or Ethernet. The Pi's own access point is one radio and is the slow path for more than one clip.

`SHARE=snapshot` stays read-only. It is a frozen view that updates about once a minute, and only while nobody is connected.

Finder may still complain about `.DS_Store`. Those files are blocked. Other files, including the `._` sidecar a Mac writes next to a clip on exFAT, go through.

Windows uses `\\dashcam.local\dashcam`. The Files app on an iPhone can open the same SMB URL.

## Play encrypted clips

Firmware 2026.20 and later can store encrypted dashcam files. The Pi copies bytes and does not have your Tesla login. After the files are on a computer:

```bash
tesdec decrypt ~/TeslaCam-copy --output ~/TeslaCam-plain
```

That tool lives in the sibling project `tesdec`. Its README covers sign-in. Decrypted output is the full-size video.

## When the car sleeps

A one-cable Pi loses power when the car drops the USB port. The Pi turns off. The files remain on the card. On the next wake the Pi boots, then the drive reappears. The car can complain if it looks for the drive during that boot; it settles once the gadget is back. Boot is on the order of half a minute.

A Pi on a separate ignition-switched supply stays up while the car is awake and turns off with the ignition. A supply that stays on all night is a drain on the 12 V battery. The share is reachable after the car sleeps only while the Pi still has power and a network.

## Troubleshooting

Run this first. It prints the board, temperature, throttle flag, USB controller, gadget, snapshot fill, mount, addresses, and SMB sessions.

```bash
sudo /usr/local/lib/dashcam-bridge/status.sh
```

`throttled=0x0` means the board has not browned out or thermally limited since boot. Any other value means it has.

| What you see | What to change |
| --- | --- |
| Laptop never shows a USB disk | The cable is charge-only, or it is in a charge-only car port. Use a data cable in the dashcam port. `status.sh` should show a UDC and `gadget:` bound to a controller |
| macOS wants to initialize the disk | Decline. Formatting from the computer replaces the drive the car is using |
| Car says the USB drive is too slow | Expected on HW4 with a USB 2 gadget. Recordings usually still land. If clips are cut off, set `GADGET_NOFUA=1` in `/etc/dashcam-bridge.env` and reboot. That trades away the last seconds of a clip when power drops |
| `throttled` is not `0x0`, or the red power LED blinks | The cable is too long or too thin, or a bus-powered Pi is also feeding an SSD. Shorten the cable, or move to the separate 5 V supply in `docs/hardware.md` |
| `dashcam.local` does not resolve | Use the address `status.sh` prints. On the access point that is `192.168.4.1`, or `10.42.0.1` if NetworkManager kept its default shared-network address |
| Share connects and `TeslaCam` is missing | Storage did not mount. `journalctl -u dashcam-storage -b` |
| `STORAGE=nvme` or `STORAGE=usb` fails at boot | No matching disk, the drive is under 64 GiB, or it already has partitions. Those partitions are left in place. Adopt a Tesla partition with `e2label`, or set `STORAGE=sd` |
| A file copied over USB is absent from the share | Eject that USB disk first. With `SHARE=live`, reopen the folder after a couple of seconds. With `SHARE=snapshot`, disconnect, wait a minute, and connect again |
| Copy fails near the end and `snapshot scratch` is near 100% | The scratch area filled while the car was still writing. Disconnect, let the refresh run, copy again. Raise `COW_GB` if you copy for a long time while the car records |
| Car asks to format on every plug | Stop the stack, delete the image, set `IMAGE_FS=exfat`, start it again (commands below). Let the car format once after that |
| Access point never appears | `WIFI_COUNTRY` is unset or wrong. Fix it in `/etc/dashcam-bridge.env` and rerun provision. `raspi-config` also sets the country |

Logs:

```bash
sudo journalctl -u dashcam-storage -u dashcam-gadget -u dashcam-wifi -b
```

## NVMe or USB disk

`STORAGE=sd` keeps the clips in `cam.img` on the boot disk. Set `STORAGE=nvme` or `STORAGE=usb` in `/etc/dashcam-bridge.env` and run `sudo ./scripts/provision.sh` to hand the car that disk directly. There is no image file on it. The snapshot scratch file stays on the boot disk.

A blank drive is partitioned ext4 and labeled `TESLA`. A drive that already holds partitions is not erased. To adopt an existing ext4 partition, label it and run provision again:

```bash
sudo e2label /dev/sda1 TESLA
```

`/dev/nvme0n1p1` is the usual internal NVMe partition. If the Pi boots from that disk, the clips stay in the image file so the OS is not erased. Two USB disks at once need the one you want labeled `TESLA`.

## Recreate the drive image

This deletes every clip on the Pi. It applies when `STORAGE=sd`, and when the NVMe or USB disk is the boot disk.

```bash
sudo systemctl stop dashcam-refresh.timer dashcam-gadget.service dashcam-storage.service
sudo rm -f /var/lib/dashcam-bridge/cam.img
# edit /etc/dashcam-bridge.env first if IMAGE_GB or IMAGE_FS should change
sudo systemctl start dashcam-storage.service dashcam-gadget.service
sudo systemctl start dashcam-refresh.timer
```

Stop the services before removing the file. The image is loop-mounted while they are running, and a delete in that state does not free the space.

With `STORAGE=usb` or `STORAGE=nvme` the clips are on that disk, not in `cam.img`. Wiping them means partitioning the disk again. Stop the services first, then erase the partition table only if you mean to delete the footage.

## Passwords and the LAN

Each saved network can reach the share. Anyone on the house LAN, or on the car's Starlink, who has `SMB_PASSWORD` can read the footage. Pick a real password. The access point is WPA2 with `AP_PSK`. Leave port 445 closed on every router. The share is for those networks and the access point, not for the public internet.

After the first provision, passwords live in `/etc/dashcam-bridge.env`. Edit that file and run `sudo ./scripts/provision.sh` again to apply a new SMB or Wi-Fi password. A reboot is required only when `config.txt` changed, and the script says so.
