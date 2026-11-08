#!/bin/bash
# Samba runs this before it opens the share. A non-zero status refuses the connection
# so a client never sees the empty mount point as if it were the drive.
findmnt -n --mountpoint "${1:-/mnt/dashcam}" >/dev/null
