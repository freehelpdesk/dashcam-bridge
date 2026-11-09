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

`SHARE=snapshot` is the default. The share is a frozen, read-only view that updates about once a minute, and only while nobody is connected. Play clips from the house Wi-Fi or Ethernet. The Pi's own access point is one radio and is the slow path for more than one clip.

## Write files to the drive

Connect to the inbox share and drop files in, using the path you want on the drive. A file at `Boombox/horn.wav` in the inbox lands at `Boombox/horn.wav` on the drive.

```text
smb://dashcam.local/dashcam-inbox
```

A file stays in the inbox until it is on the drive, so an empty inbox means everything was written. To cancel, delete the file before it goes. A file with the same name as one on the drive replaces it. The inbox adds and replaces files. It cannot delete anything from the drive.

The car and the Pi never write the drive at the same time. The Pi waits until nothing has changed in the inbox for a minute and the car has written nothing for two minutes. Then it disconnects the USB drive from the car, copies the files, and reconnects it. The car may briefly report that the USB drive is missing. While the car is driving or Sentry is recording, it keeps writing, so files wait until it stops.

Each write takes at most about a minute, and anything left over goes at the next idle moment. If the power is cut partway through, the files are still in the inbox and are written again. The view on the `dashcam` share shows new files at its next update after you disconnect. `status.sh` shows how many files are waiting, and the journal lists each one:

```bash
sudo journalctl -u dashcam-inbox -b
```

A file that cannot be written, for example because the drive is full, is retried an hour later, or sooner if you add something new to the inbox.

## Live mode

`SHARE=live` makes the `dashcam` share itself writable, with no inbox. A file you put there is on the drive the car sees, but nothing stops the car and the Pi from writing at the same moment, and that can corrupt the drive. Eject the USB disk on any computer that had it open before you write, and do not write while the car has that disk open. A file copied onto the USB disk shows up after you disconnect from the share, within a couple of seconds.

Finder may still complain about `.DS_Store`. Those files are blocked. Other files, including the `._` sidecar a Mac writes next to a clip on exFAT, go through.

Windows uses `\\dashcam.local\dashcam`. The Files app on an iPhone can open the same SMB URL.

## Play encrypted clips

Firmware 2026.20 and later can store encrypted dashcam files. The Pi copies bytes and does not have your Tesla login. After the files are on a computer:

```bash
tesdec decrypt ~/TeslaCam-copy --output ~/TeslaCam-plain
```

That tool lives in the sibling project `tesdec`. Its README covers sign-in. Decrypted output is the full-size video.

## Telemetry and alerts

With `TELEMETRY=1` the Pi reads the metadata Tesla embeds in each front-camera clip: speed, pedal, brake, steering, blinkers, Autopilot state, GPS, heading, and acceleration. It needs firmware 2025.44.25 or later on HW3 or above, and unencrypted clips. A parked car usually records no metadata.

A clip has to finish before the Pi can read it, and clips are about a minute long. An alert arrives a few seconds to just over a minute after the event, and only while the Pi has power and a network. A missed alert is retried when the network comes back. Clips from a backlog are stored, but only the newest three can alert.

Set `TELEMETRY_TOKEN` in `/etc/dashcam-bridge.env`, set `TELEMETRY=1`, run provision, and reboot if it says to. Send the token with every request:

```bash
curl -H "Authorization: Bearer $TOKEN" http://dashcam.local:8088/latest
```

| Path | What it returns |
| --- | --- |
| `/healthz` | `{"ok":true}`, with no token needed |
| `/latest` | The newest stored sample |
| `/samples?since=&limit=` | Samples at two per second, oldest first. `since` is Unix time. At most 5000 |
| `/events?since=&type=&limit=` | Hard events, newest first. `type` is `hard_brake`, `hard_accel`, or `hard_corner` |
| `/status` | Newest clip, row counts, pending alerts, and scanner health |
| `/stream` | Server-sent `sample` and `alert` events. They arrive in a burst as each clip finishes |

Acceleration is in m/s². `accel_long` is positive when speeding up and `accel_lat` is side to side. Detection uses every frame, and an event has to last `TELEMETRY_HOLD_MS`. Braking and acceleration also have to show up in the speed, so a pothole does not alert. In `/status`, `axis_correlation` should be near 1. A value near 0 or below means this car reports its axes differently.

Times come from the car's clip names, read in the Pi's time zone. The API is plain HTTP, so the token and your location cross the network unencrypted. Use it on networks you trust, and never forward the port on a router. Alerts leave out the location, city, and street unless `TELEMETRY_WEBHOOK_GPS=1`.

### Choosing alerts

Set `TELEMETRY_ALERT_<NAME>` to `off`, `log`, or `alert`. `log` stores the event and shows it on the API but never sends it. `alert` also sends it, to `TELEMETRY_ALERT_<NAME>_WEBHOOK` if that is set, or to `TELEMETRY_WEBHOOK_URL` if not. Add `TELEMETRY_ALERT_<NAME>_WEBHOOK_FORMAT=text` when one service needs a different format. Thresholds and zones are described in `config/dashcam-bridge.env`. After a change, run provision. `/status` lists each alert's mode.

| `<NAME>` | Default | What it reports |
| --- | --- | --- |
| `HARD_BRAKE`, `HARD_ACCEL`, `HARD_CORNER` | `alert` | Sustained force above a threshold |
| `AUTOPILOT_TAKEOVER` | `alert` | Autopilot or FSD ended alongside hard braking or a sharp steering input. It cannot tell who ended it |
| `TRIP_SUMMARY` | `alert` | When the car is put in park: distance, time, top speed, Autopilot share, event count |
| `SENTRY_EVENT`, `SAVED_CLIP` | `alert` | A new folder on the drive, with the reason the car recorded |
| `RECORDING_STOPPED` | `alert` | No new clip for five minutes during a drive |
| `POWER_TROUBLE` | `alert` | Undervoltage, throttling, or a temperature limit. Once per flag per boot. A brown-out that resets the Pi clears the flag first |
| `IMPACT` | `off` | A very short, sharp force. Treat it as a record: a crash can cut power before the clip finishes, or leave the Pi offline, so it is not an emergency alert |
| `SWERVE` | `off` | Steering swung both ways at speed, with side force |
| `POTHOLE` | `off` | A vertical jolt with its GPS position. `log` builds a map through `/events?type=pothole` without any pings |
| `LANE_NO_BLINKER` | `off` | Estimated from the heading, so some will be wrong |
| `BLINKER_LEFT_ON` | `off` | A blinker on for 30 seconds at highway speed |
| `SPEEDING` | `off` | Above a fixed limit, or per GPS zone. It does not know posted limits |
| `GEOFENCE` | `off` | Arrived at or left a named place. Needs `TELEMETRY_GEOFENCE_ZONES` |
| `UNEXPECTED_USE` | `off` | A drive starting in quiet hours, or going outside an area |
| `STORAGE_FULL` | `off` | The drive or the snapshot scratch is nearly full |
| `TELEMETRY_LOST` | `off` | 240 clips in a row with no SEI, or the car starting to encrypt clips |

Only finished clips can alert, so these arrive after the fact. A parked car usually has no SEI, so its alerts come from new folders on the drive rather than from the car's data.

The scanner reads a private, read-only view of the drive that the kernel will not let it write to, so it cannot disturb what the car is recording. It works the same in both `SHARE` modes.

### Measure the write timing

To find out whether reading the disk as the car writes could beat the one-minute delay, set `TELEMETRY_WRITE_LOG=1`, run provision, reboot, and go for a drive. The log stops after an hour of writing. Back home:

```bash
sudo python3 /usr/local/lib/dashcam-bridge/telemetry.py write-report
```

`p95_gap_s` is the key number: how long the car can go between writes. Set `TELEMETRY_WRITE_LOG=0` afterward, because logging flushes the disk every second.

## When the car sleeps

A one-cable Pi loses power when the car drops the USB port. The Pi turns off. The files remain on the card. On the next wake the Pi boots, then the drive reappears. The car can complain if it looks for the drive during that boot; it settles once the gadget is back. The drive is presented early in boot, before the Pi's network and SMB share are ready, and the share follows later. To see how long the car waited:

```bash
sudo journalctl -u dashcam-gadget -b | grep bound
```

That time counts from when the kernel started. Add a few seconds for the Pi's firmware, which runs first.

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
| `throttled` is not `0x0`, or the red power LED blinks | The cable is too long or too thin, or a bus-powered Pi is also feeding an SSD. Shorten the cable, or move to the separate 5 V supply in `docs/hardware.md`. On a Pi 5, `REDUCED_POWER=1` lowers the peak current. Run provision and reboot after setting it |
| `dashcam.local` does not resolve | Use the address `status.sh` prints. On the access point that is `192.168.4.1`, or `10.42.0.1` if NetworkManager kept its default shared-network address |
| The share refuses the connection | The drive did not mount on the Pi, or it has not finished mounting since boot. The car can still record to it. `journalctl -u dashcam-share -b` |
| `STORAGE=nvme` or `STORAGE=usb` fails at boot | No matching disk appeared within 30 seconds, the drive is under 64 GiB, or it is a new drive that already has partitions. Those partitions are left in place. Adopt a Tesla partition with `e2label`, or set `STORAGE=sd` |
| A file copied over USB is absent from the share | Eject that USB disk first. With `SHARE=snapshot`, disconnect, wait a minute, and connect again. With `SHARE=live`, reopen the folder after a couple of seconds |
| Telemetry has no new data | `journalctl -u dashcam-telemetry-scan -b`. A parked car records no metadata. `encrypted_recent` above 0 in `/status` means the car may be writing encrypted clips, which the Pi cannot read |
| A file stays in the inbox | The car is still writing, the file is still open on a computer, or it could not be written. `journalctl -u dashcam-inbox -b` |
| Copy fails near the end and `snapshot scratch` is near 100% | The scratch area filled while the car was still writing. Disconnect, let the refresh run, copy again. Raise `COW_GB` if you copy for a long time while the car records |
| Car asks to format on every plug | Stop the stack, delete the image, set `IMAGE_FS=exfat`, start it again (commands below). Let the car format once after that |
| Access point never appears | `WIFI_COUNTRY` is unset or wrong. Fix it in `/etc/dashcam-bridge.env` and rerun provision. `raspi-config` also sets the country |

Logs:

```bash
sudo journalctl -u dashcam-storage -u dashcam-gadget -u dashcam-share -u dashcam-wifi -b
```

## NVMe or USB disk

`STORAGE=sd` keeps the clips in `cam.img` on the boot disk. Set `STORAGE=nvme` or `STORAGE=usb` in `/etc/dashcam-bridge.env` and run `sudo ./scripts/provision.sh` to hand the car that disk directly. There is no image file on it. The snapshot scratch file stays on the boot disk.

A blank drive is partitioned ext4 and labeled `TESLA`. A drive that already holds partitions is not erased. To adopt an existing ext4 partition, label it and run provision again:

```bash
sudo e2label /dev/sda1 TESLA
```

`/dev/nvme0n1p1` is the usual internal NVMe partition. If the Pi boots from that disk, the clips stay in the image file so the OS is not erased. The exception is a separate partition on the boot disk labeled `TESLA`: the car gets that partition and nothing else. Two USB disks at once need the one you want labeled `TESLA`.

The Pi remembers the disk it gave the car by its hardware serial number, so the car reformatting that disk does not lock it out. A different disk is treated as new.

## Recreate the drive image

This deletes every clip on the Pi. It applies when `STORAGE=sd`, and when the NVMe or USB disk is the boot disk.

```bash
sudo systemctl stop dashcam-refresh.timer dashcam-gadget.service dashcam-storage.service
sudo rm -f /var/lib/dashcam-bridge/cam.img
# edit /etc/dashcam-bridge.env first if IMAGE_GB or IMAGE_FS should change
sudo systemctl start dashcam-storage.service dashcam-gadget.service dashcam-share.service
sudo systemctl start dashcam-refresh.timer
```

Stop the services before removing the file. The image is loop-mounted while they are running, and a delete in that state does not free the space.

With `STORAGE=usb` or `STORAGE=nvme` the clips are on that disk, not in `cam.img`. Wiping them means partitioning the disk again. Stop the services first, then erase the partition table only if you mean to delete the footage.

## Update from a Mac

Once SSH works, push your working tree from the repo on your Mac:

```bash
tools/push-to-pi.sh
```

It runs the tests, copies the files to `~/dashcam-bridge` on the Pi, runs provision, and confirms storage, the USB drive, and the share came back. It sends uncommitted changes too, but not files ignored by git. It asks for the Pi's `sudo` password if one is needed, so run it from a terminal.

| Option | What it does |
| --- | --- |
| `--sync-only` | Copies the files and restarts nothing |
| `--reboot` | Reboots too, if provision says one is needed. Without it, the USB drive stays down until you reboot |
| `--force` | Goes ahead even though the car is writing, which interrupts the recording |
| `--skip-tests` | Does not run `tests/run.sh` first. The tests need `brew install bash`, and are skipped if it is missing |
| `--dry-run` | Lists what would be sent |
| `--host user@host` | Another Pi. `DASHCAM_PI` sets the default |

The push stops if the car is writing to the drive, because provision disconnects it for a moment. Your settings are safe: they stay in `/etc/dashcam-bridge.env`, and the repo's env file is not sent to a provisioned Pi. New options are added to the end of that file as comments at their defaults, so a push never changes what is switched on. Passwords, tokens, webhooks, and SSIDs are blanked in the list of options the Pi receives. To change a setting, edit that file on the Pi and push again. The Pi needs internet access for provision's package check.

The files are swapped in only after all of them arrive. The last version stays in `~/dashcam-bridge.previous`. To go back, move it into place and run `sudo ./scripts/provision.sh` from it.

## Passwords and the LAN

Each saved network can reach the share. Anyone on the house LAN, or on the car's Starlink, who has `SMB_PASSWORD` can read the footage and add or replace files through the inbox. With `SHARE=live` they can also delete it. With `TELEMETRY=1`, anyone with `TELEMETRY_TOKEN` can read the car's location history. Pick a real password. The access point is WPA2 with `AP_PSK`. Leave port 445 closed on every router. The share is for those networks and the access point, not for the public internet.

After the first provision, passwords live in `/etc/dashcam-bridge.env`. Edit that file and run `sudo ./scripts/provision.sh` again to apply a new SMB or Wi-Fi password. A reboot is required only when `config.txt` changed, and the script says so.
