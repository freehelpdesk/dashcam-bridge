# dashcam-bridge

A Raspberry Pi that plugs into the USB port a Tesla uses for dashcam storage. The car writes its original camera files to the Pi, the same way it writes to a USB stick. The Pi serves those files over SMB as a frozen snapshot. To put a file on the drive, drop it on the `dashcam-inbox` share, and the Pi writes it once the car is idle.

Nothing is transcoded. The share is the full-size copy that lives on the USB drive, which is a different thing from the smaller preview in the phone app.

```
  car (USB host)                         laptop or phone
        |                                      |
        | USB-C, the car's dashcam port        | Wi-Fi, SMB
        v                                      v
  +--------------------------------------------------+
  | Pi                                               |
  |   USB gadget  ->  disk image  ->  snapshot       |
  |                                    |             |
  |                                    +-->  Samba   |
  +--------------------------------------------------+
```

The car is the USB host. The Pi pretends to be the stick. Wi-Fi is the side door you copy files through. Plug the car into the Pi's USB-C port. The USB-A ports are host ports, and the car is already the host.

Clips recorded on firmware 2026.20 and later may be encrypted. The share still has the original bytes. Decrypt them on a computer with [tesdec](../tesdec). Sign-in and decryption stay on that computer.

## Buy

Buy a **Raspberry Pi 4 Model B, 2 GB or 4 GB**, for a Pi that the car's USB port can power through one data cable, with 5 GHz Wi-Fi fast enough to copy full-size clips.

Buy a **Raspberry Pi 5, 4 GB**, when the Pi will have its own 5 V / 5 A supply and an NVMe drive. The link to the car is the same USB 2 speed as the Pi 4. The gain is the disk and the thermals.

The Pi Zero 2 W fits a glovebox and is a poor fit for this job: its Wi-Fi is 2.4 GHz only. A full comparison, the cable, the power wiring, and the card to buy are in [docs/hardware.md](docs/hardware.md).

## Build

Flash **Raspberry Pi OS Lite (64-bit)** and run `scripts/provision.sh` on the Pi. The script installs Samba, the USB gadget, and the snapshot share. There is no custom kernel. Details, the boot config, and a bench test are in [docs/build.md](docs/build.md).

```bash
# on the Pi, after editing config/dashcam-bridge.env
sudo ./scripts/provision.sh
sudo reboot
```

`STORAGE=nvme` uses the Pi's internal NVMe as the drive the car writes. `STORAGE=usb` does the same with an external USB disk. The default, `STORAGE=sd`, keeps the clips in an image file on the boot disk.

## Pull files

The Pi joins the house Wi-Fi whenever that network is on, and the car's Starlink when the house is not. Both go in `config/dashcam-bridge.env` (`WIFI_NET_1` for the house, `WIFI_NET_2` for Starlink). From a Mac on that same network:

```text
smb://dashcam.local/dashcam
```

User `dashcam`, password `SMB_PASSWORD` from the env file. The folders under `TeslaCam/` are `SavedClips`, `SentryClips`, and `RecentClips`. The view updates about once a minute while nobody is connected. Day-to-day use and fixes are in [docs/operations.md](docs/operations.md).

## Layout

| Path | What it is |
| --- | --- |
| `docs/hardware.md` | Which Pi, power, cable, storage, heat |
| `docs/build.md` | OS image, boot config, packages, provision |
| `docs/operations.md` | Connecting, copying, troubleshooting |
| `config/dashcam-bridge.env` | Passwords, image size, Wi-Fi |
| `config/smb.conf` | The SMB share |
| `config/boot/config.txt.fragment` | USB device-mode overlay |
| `scripts/provision.sh` | Applies the config on the Pi |
| `systemd/` | Boot services |
| `tests/run.sh` | Logic tests that need no Pi: `bash tests/run.sh` |
