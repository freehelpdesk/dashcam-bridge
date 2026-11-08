# Which Pi to buy

Buy a Raspberry Pi 4 Model B with 2 GB of RAM. It is the board that matches a one-cable install: the car's dashcam USB port can power it, its USB-C port can be the drive the car writes to, and its 5 GHz Wi-Fi is in the right range for copying full-size clips to a laptop.

Get the 4 GB Pi 4 if the price is close. The extra RAM becomes file cache while a multi-gigabyte clip is copying.

Buy a Raspberry Pi 5 with 4 GB when you can give it a real 5 V / 5 A supply and you want the footage on NVMe. The Pi 5 uses the same Wi-Fi chip as the Pi 4 (the Infineon CYW43455, 802.11ac), so a copy across the cabin lands in the same speed range. What it adds is a PCIe lane for an M.2 drive, a faster SD controller, and more CPU headroom while Samba is busy. Its USB-C device port is USB 2, same as the Pi 4, so the car sees the same kind of stick.

## One-cable parts list

This is the build to order if the Pi lives in the glovebox and the car's USB port is the only power source.

- Raspberry Pi 4 Model B, 2 GB or 4 GB
- Official Raspberry Pi 4 USB-C power supply, used on the bench. It occupies the same USB-C port the car needs, so it comes off before the car cable goes on
- 256 GB or 512 GB high-endurance microSD, the kind sold for dashcams (Samsung PRO Endurance, SanDisk MAX Endurance). A normal card dies under all-day recording
- A heatsink case. A closed car in the sun is a hot place for a bare board
- A short USB data cable from the car's dashcam port to the Pi's USB-C port. USB-A to USB-C, or USB-C to USB-C. It has to carry data. A charge-only cable is the usual reason a new build shows no drive
- A microSD reader for the computer that flashes the card

A 256 GB card holds the OS, a 128 GB drive image, and 16 GB of snapshot scratch at the defaults in `config/dashcam-bridge.env`. A 512 GB card can take `IMAGE_GB=256`, which gives the car a larger rolling history.

## Separate-power parts list

This is the build to order when the footage should live on an SSD or NVMe, or when you want the share to stay up after the car goes to sleep.

- Raspberry Pi 5, 4 GB, or a Pi 4 if you already have one and only need the SSD
- Official active cooler on a Pi 5
- Official 27 W USB-C supply, for the bench
- Raspberry Pi M.2 HAT+ and a 500 GB NVMe drive, or a USB 3 SSD on a blue USB-A port
- A small microSD for the OS if you are not booting from NVMe
- An ignition-switched, regulated 5 V supply that can hold 5 A for a Pi 5 (3 A is enough for a Pi 4 with no SSD). Feed it to the GPIO header. The USB-C port stays the data connection to the car
- A USB data-only adapter (a USB power blocker) on the cable between the Pi and the car

The Pi 5 with an M.2 HAT is taller than a bare Pi 4. Measure the glovebox. A tight glovebox means the Pi sits under a seat or in the trunk and a data cable runs to the dashcam port.

## What the car actually sees

Every current Raspberry Pi speaks USB 2.0 on the port that can act as a device.

| Board | Port the car plugs into | Speed the car sees | Wi-Fi | Power from the car's USB port |
| --- | --- | --- | --- | --- |
| Pi 4 Model B | USB-C | USB 2 | 2.4 and 5 GHz | Yes. This is the one-cable build |
| Pi 5 | USB-C | USB 2 | 2.4 and 5 GHz | Often brown-out. Use a separate 5 V / 5 A supply |
| Pi Zero 2 W | Micro-USB port marked USB, not PWR | USB 2 | 2.4 GHz only | Yes. Copies of multi-GB clips are slow |
| Pi 3 Model B and older | None. The USB-A ports are hosts | — | — | Cannot face the car as a drive |
| Compute Module 4 / 5 | Depends on the carrier | USB 2 on the official CM4 IO board | Depends on the carrier | A carrier-board project, not the first build |

Tesla asks for a drive with a sustained write of at least 4 MB/s. USB 2 clears that. Newer cars (HW4) can still show "USB drive too slow", because their bar sits above 4 MB/s and a Pi gadget is USB 2. That warning is about the link into the car. The files on the share are the bytes the car wrote.

The car link stays USB 2 on a Pi 4 and a Pi 5. The blue USB-A ports are host ports. USB 3 device mode needs a different board (boards such as the Rock 4C+ show up in other projects for that reason). This project targets a Raspberry Pi.

## Power

Use one 5 V source.

**One cable, Pi 4.** The car is the USB host, so its port supplies VBUS and data together. Plug the dashcam USB port into the Pi's USB-C with a short data cable. Leave the GPIO 5 V pins empty. A long, thin cable sags under load and the Pi brown-outs. `docs/operations.md` shows how to read the throttle flag.

On the bench, the official USB-C supply powers the Pi for SSH and `provision.sh`. Unplug it before the car cable goes on. Both want the same socket.

**Separate supply.** The USB-C port is still the data port, so power has to come in somewhere else. Use a regulated 5 V supply on the 40-pin header: physical pin 2 or pin 4 is 5 V, physical pin 6 is ground. Check the pins with a meter before the first connection. A wrong pin destroys the board. The cable from the USB-C port to the car has to be data-only, through a USB power blocker, so the car's 5 V and the GPIO supply never meet.

Switch that supply with the ignition, or accept that an always-on Pi is a drain on the 12 V battery. A one-cable Pi avoids that drain: the car cuts USB power when it sleeps, and the Pi turns off. The files stay on the card. The share comes back on the next wake, after the Pi boots.

A Pi 5 on a car USB port often logs undervoltage and will throttle. An NVMe HAT makes that worse. Give a Pi 5 the separate supply.

**How much the car's port can give.** With `POWER_SOURCE=bus`, the Pi requests 500 mA from the car, the most USB 2 lets a device ask for. That number is a request and does not limit the Pi. A bare Pi 4 typically draws 0.6 A idle and up to 1.25 A under load, so it already takes more than it asked for. The real limit is what the port and cable can deliver before the voltage falls below about 4.63 V, which is where the Pi logs undervoltage. Software cannot raise that. A shorter, thicker cable can.

A Pi 5 also limits its USB-A ports to 600 mA unless its supply negotiates 5 A, and provision raises that to 1.6 A. A Pi 4 has a fixed 1.2 A limit. An SSD on those ports takes its current from the car's port too, so the higher limit makes a brown-out more likely on a weak port. `status.sh` shows the requested current and, on a Pi 5, the live supply voltage.

## Storage

The car writes all day. That write stream should land on an endurance microSD, or on an SSD / NVMe when the power budget allows.

The OS and the footage can share one endurance card. That is the one-cable build. Leave `STORAGE=sd`. The image file `cam.img` is created in `IMAGE_DIR` (`/var/lib/dashcam-bridge`) on first boot.

Set `STORAGE=nvme` when a Pi 5 has an internal NVMe (the M.2 HAT+) and the car should write straight to that drive. Set `STORAGE=usb` for an external USB disk, such as a USB 3 SSD on a Pi 4 blue USB-A port. A blank drive is partitioned as the Tesla disk. The SD card holds the OS and the snapshot scratch. A drive that already has its own partitions is left alone. If the Pi boots from that disk, the clips stay in the image file so the OS is not erased. The drive has to be at least 64 GiB. `COW_GB` has to fit on the boot disk.

An SSD or NVMe draws current through the Pi. On a one-cable Pi 4 that extra current is a common cause of undervoltage. Prefer the extra disk once the Pi has its own supply.

The drive the car sees is ext4, labeled `TESLA`, with `TeslaCam/RecentClips`, `SavedClips`, and `SentryClips` already created so the car has less reason to offer a format. On `STORAGE=sd` that drive is the image file. On USB or NVMe it is the disk. Tesla's drive requirements allow ext4. If a particular car keeps asking to format, set `IMAGE_FS=exfat` and recreate the drive. The steps are in `docs/operations.md`.

The image should be at least 64 GB because that is Tesla's floor. The default is 128 GB. Recent clips are a rolling buffer: a larger image keeps more of them before the car overwrites the oldest.

## Heat

A glovebox or cabin in summer runs hot enough to throttle a bare Pi. Throttling slows the SMB copy. It does not change the files.

- Pi 4: a metal heatsink case, with air around it. The dashboard in direct sun is a worse spot than the glovebox
- Pi 5: the official active cooler. The fan needs the power budget above

## Wi-Fi, in practical numbers

Full quality means the file bytes are the camera originals. Wi-Fi is how you copy finished clips off the drive. The cabin radio and the camera bitrate are separate numbers.

On the Pi's built-in 802.11ac radio, a copy inside a car is typically on the order of 10 MB/s on 5 GHz. A few gigabytes takes a few minutes. The 2.4 GHz radio on a Zero is several times slower, which is why that board is a poor fit when the point of the project is pulling full-size video.

Saved networks are listed in the env file. The house should be `WIFI_NET_1` at priority 100, and the car's Starlink `WIFI_NET_2` at a lower priority. The Pi joins the house whenever that network is on, including when Starlink is louder. On the road, with the house out of range, it joins Starlink. The laptop then opens `smb://dashcam.local/dashcam` on whichever of those networks it is also on. When none of the saved networks are in range, the Pi starts its own access point, `dashcam`, at `192.168.4.1`.
