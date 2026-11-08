#!/usr/bin/env python3
"""Telemetry from the SEI metadata in Tesla dashcam clips.

scan          root. Reads each finished front-camera clip into SQLite.
serve         unprivileged. HTTP API on a port, and webhook alerts.
write-log     root. Records when the car's writes reach the Pi, for one drive.
write-report  Summarizes the newest write log.
check         Parses clips without touching a database. Prints no GPS.
write-config  Writes the JSON config from the TELEMETRY_* environment.

Standard library only. The SEI layout is Tesla's:
https://github.com/teslamotors/dashcam
"""
import argparse
import contextlib
import datetime
import fcntl
import glob
import hmac
import json
import math
import os
import re
import signal
import sqlite3
import statistics
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = "/etc/dashcam-bridge-telemetry.json"
DATA_DIR = "/var/lib/dashcam-telemetry"
DB_PATH = DATA_DIR + "/telemetry.db"
LOCK_PATH = "/run/dashcam-bridge/lock"
ORIGIN = "/dev/mapper/dashcam-origin"
VIEW_NAME = "dashcam-telem"
VIEW_DEV = "/dev/mapper/" + VIEW_NAME
VIEW_MOUNT = "/run/dashcam-bridge/telemetry"
CLIPS_DIR = "TeslaCam/RecentClips"
ENCRYPTED_DIR = "TeslaCam/EncryptedClips/RecentClips"
FRONT_CLIP = re.compile(r"^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})-front\.mp4$")

STORE_HZ = 2.0            # Detection uses every frame. The database keeps this many per second.
SMOOTH_SECS = 0.1         # Averaged before detection, so one noisy frame cannot split an event.
MIN_SPEED_MPS = 1.5       # Below walking pace, a jolt is not a driving event.
MERGE_SECS = 2.0          # The same kind of event this close together is one event.
MIN_DV_FRACTION = 0.4     # The speed change has to show at least this share of the measured force.
MAX_BATCH = 10            # Clips per lock hold, so a backlog cannot starve the other scripts.
ALERT_NEWEST = 3          # A backlog alerts only for its newest clips, so old drives stay quiet.
RETRY_NEWEST = 30         # Scans to wait on the newest clip, which may still be recording.
RETRY_OLDER = 3           # Scans to wait on a clip with a newer one behind it.
MAX_SEI_BYTES = 4096
MAX_MOOV_BYTES = 16 * 1024 * 1024
MAX_STREAMS = 8
MAX_ROWS = 5000
ALERT_MAX_ATTEMPTS = 48
WRITE_LOG_ACTIVE_SECS = 3600
WRITE_LOG_KEEP = 10

GEARS = {0: "park", 1: "drive", 2: "reverse", 3: "neutral"}
AUTOPILOT = {0: "none", 1: "self_driving", 2: "autosteer", 3: "tacc"}
LABELS = {"hard_brake": "Hard braking", "hard_accel": "Hard acceleration", "hard_corner": "Hard cornering"}


def say(message):
    print(message, flush=True)


# --- parsing ---------------------------------------------------------------


def read_varint(data, i):
    value = shift = 0
    while True:
        byte = data[i]
        i += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, i
        if shift > 70:
            raise ValueError("varint too long")


def parse_protobuf(data):
    fields = {}
    i = 0
    while i < len(data):
        key, i = read_varint(data, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = read_varint(data, i)
        elif wire in (1, 5):
            width = 8 if wire == 1 else 4
            value = data[i:i + width]
            i += width
        elif wire == 2:
            length, i = read_varint(data, i)
            value = data[i:i + length]
            i += length
        else:
            raise ValueError("unsupported wire type")
        if i > len(data):
            raise ValueError("truncated field")
        fields[number] = (wire, value)
    return fields


def strip_emulation_prevention(data):
    out = bytearray()
    zeros = 0
    for byte in data:
        if zeros >= 2 and byte == 3:
            zeros = 0
            continue
        out.append(byte)
        zeros = 0 if byte else zeros + 1
    return bytes(out)


def sei_payload(nal):
    """Return the protobuf inside an SEI NAL, or None. Follows Tesla's extractor."""
    for i in range(3, len(nal) - 1):
        if nal[i] == 0x42:
            continue
        if nal[i] == 0x69 and i > 2:
            return strip_emulation_prevention(nal[i + 1:-1])
        return None
    return None


def _number(fields, number, wire, fmt):
    item = fields.get(number)
    if not item or item[0] != wire or len(item[1]) != struct.calcsize(fmt):
        return 0.0
    value = struct.unpack(fmt, item[1])[0]
    return value if math.isfinite(value) else 0.0


def _varint(fields, number):
    item = fields.get(number)
    return item[1] if item and item[0] == 0 else 0


def decode_sample(payload):
    """Decode one SeiMetadata message. Protobuf leaves out any field that is zero."""
    fields = parse_protobuf(payload)
    return {
        "gear": _varint(fields, 2),
        "frame": _varint(fields, 3),
        "speed": _number(fields, 4, 5, "<f"),
        "pedal": _number(fields, 5, 5, "<f"),
        "steering": _number(fields, 6, 5, "<f"),
        "blinker_left": bool(_varint(fields, 7)),
        "blinker_right": bool(_varint(fields, 8)),
        "brake": bool(_varint(fields, 9)),
        "autopilot": _varint(fields, 10),
        "lat": _number(fields, 11, 1, "<d"),
        "lon": _number(fields, 12, 1, "<d"),
        "heading": _number(fields, 13, 1, "<d"),
        # Measured on real driving: speed change follows -y, so y is the car's
        # long axis with forward negative, and x is the side axis.
        "accel_long": -_number(fields, 15, 1, "<d"),
        "accel_lat": _number(fields, 14, 1, "<d"),
        "accel_z": _number(fields, 16, 1, "<d"),
    }


def _atoms(fp, size):
    """Top-level MP4 atoms as {type: (offset, length, header)}, or None if unfinished."""
    atoms = {}
    pos = 0
    while pos < size:
        fp.seek(pos)
        head = fp.read(16)
        if len(head) < 8:
            return None
        length, kind = struct.unpack(">I4s", head[:8])
        header = 8
        if length == 1:
            if len(head) < 16:
                return None
            length = struct.unpack(">Q", head[8:16])[0]
            header = 16
        # A length of 0 means "to the end of the file", which only an unfinished clip uses.
        if length < header or pos + length > size:
            return None
        atoms.setdefault(kind, (pos, length, header))
        pos += length
    return atoms


def _duration(fp, moov):
    """Clip length from mvhd. Falls back to a typical clip."""
    offset, length, header = moov
    if length > MAX_MOOV_BYTES:
        return 60.0
    fp.seek(offset + header)
    body = fp.read(length - header)
    at = body.find(b"mvhd")
    if at < 0 or at + 40 > len(body):
        return 60.0
    version = body[at + 4]
    if version == 1:
        scale, ticks = struct.unpack(">IQ", body[at + 24:at + 36])
    else:
        scale, ticks = struct.unpack(">II", body[at + 16:at + 24])
    return ticks / scale if scale and ticks else 60.0


def read_clip(path):
    """Return {"duration", "samples"}, or None until the car has finished the clip."""
    samples = []
    with open(path, "rb") as fp:
        size = os.fstat(fp.fileno()).st_size
        atoms = _atoms(fp, size)
        if not atoms or b"mdat" not in atoms or b"moov" not in atoms:
            return None
        duration = _duration(fp, atoms[b"moov"])
        offset, length, header = atoms[b"mdat"]
        fp.seek(offset + header)
        left = length - header
        short = 0
        while left >= 4:
            raw = fp.read(4)
            if len(raw) < 4:
                return None
            nal_size = struct.unpack(">I", raw)[0]
            left -= 4
            if nal_size > left:
                return None
            if nal_size < 2:
                # A few are harmless. Long runs are zeroed blocks not yet written.
                short += 1
                if short > 16:
                    return None
                fp.seek(nal_size, 1)
                left -= nal_size
                continue
            head = fp.read(2)
            if len(head) < 2:
                return None
            if (head[0] & 0x1F) == 6 and head[1] == 5 and nal_size <= MAX_SEI_BYTES:
                body = fp.read(nal_size - 2)
                if len(body) < nal_size - 2:
                    return None
                payload = sei_payload(head + body)
                if payload:
                    with contextlib.suppress(ValueError, IndexError, struct.error):
                        samples.append(decode_sample(payload))
            else:
                fp.seek(nal_size - 2, 1)
            left -= nal_size
    count = len(samples)
    for index, sample in enumerate(samples):
        sample["offset"] = index * duration / count
    return {"duration": duration, "samples": samples}


# --- detection -------------------------------------------------------------


def smooth(values, window):
    if window <= 1:
        return list(values)
    half = window // 2
    total = [0.0]
    for value in values:
        total.append(total[-1] + value)
    out = []
    for i in range(len(values)):
        low = max(0, i - half)
        high = min(len(values), i + half + 1)
        out.append((total[high] - total[low]) / (high - low))
    return out


def _runs(values, samples, threshold, hold):
    """Stretches at or above threshold, while moving, that last at least hold seconds."""
    runs = []
    start = None
    for i in range(len(values) + 1):
        active = i < len(values) and values[i] >= threshold and samples[i]["speed"] >= MIN_SPEED_MPS
        if active and start is None:
            start = i
        elif not active and start is not None:
            if samples[i - 1]["offset"] - samples[start]["offset"] >= hold:
                runs.append((start, i - 1))
            start = None
    return runs


def _merge(runs, samples):
    merged = []
    for run in runs:
        if merged and samples[run[0]]["offset"] - samples[merged[-1][1]]["offset"] <= MERGE_SECS:
            merged[-1] = (merged[-1][0], run[1])
        else:
            merged.append(run)
    return merged


def detect_events(clip, cfg):
    """Find hard braking, acceleration, and cornering in one clip."""
    samples = clip["samples"]
    if len(samples) < 2 or clip["duration"] <= 0:
        return []
    hz = len(samples) / clip["duration"]
    window = max(1, round(SMOOTH_SECS * hz))
    hold = cfg["hold_ms"] / 1000
    long_axis = smooth([s["accel_long"] for s in samples], window)
    side_axis = smooth([abs(s["accel_lat"]) for s in samples], window)
    checks = (
        ("hard_brake", [-v for v in long_axis], cfg["brake_mps2"], -1),
        ("hard_accel", long_axis, cfg["accel_mps2"], 1),
        ("hard_corner", side_axis, cfg["corner_mps2"], 0),
    )
    events = []
    for kind, values, threshold, direction in checks:
        for first, last in _merge(_runs(values, samples, threshold, hold), samples):
            peak = max(values[first:last + 1])
            if direction:
                # The speed has to agree, so a pothole or a bad axis cannot alert.
                span = samples[last]["offset"] - samples[first]["offset"]
                change = (samples[last]["speed"] - samples[first]["speed"]) * direction
                mean = sum(values[first:last + 1]) / (last - first + 1)
                if change < MIN_DV_FRACTION * mean * span:
                    continue
            start = samples[first]
            events.append({
                "type": kind,
                "offset_start": start["offset"],
                "offset_end": samples[last]["offset"],
                "peak": round(peak, 3),
                "speed_start": round(start["speed"], 3),
                "speed_end": round(samples[last]["speed"], 3),
                "lat": start["lat"],
                "lon": start["lon"],
                "heading": start["heading"],
            })
    events.sort(key=lambda event: event["offset_start"])
    return events


def axis_correlation(clip):
    """How well the long axis tracks the speed change. None if the clip cannot say."""
    samples = clip["samples"]
    if len(samples) < 2 or clip["duration"] <= 0:
        return None
    step = max(1, round(len(samples) / clip["duration"]))
    changes, forces = [], []
    for i in range(0, len(samples) - step, step):
        span = samples[i + step]["offset"] - samples[i]["offset"]
        if span <= 0:
            continue
        changes.append((samples[i + step]["speed"] - samples[i]["speed"]) / span)
        forces.append(sum(s["accel_long"] for s in samples[i:i + step]) / step)
    if len(changes) < 5 or max(abs(v) for v in changes) < 1.0:
        return None
    try:
        return round(statistics.correlation(changes, forces), 3)
    except statistics.StatisticsError:
        return None


def clip_start(name):
    stamp = FRONT_CLIP.match(name).group(1)
    return datetime.datetime.strptime(stamp, "%Y-%m-%d_%H-%M-%S").timestamp()


# --- database --------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS clips (
  name TEXT PRIMARY KEY, start_t REAL, parsed_at REAL, status TEXT,
  sei_count INTEGER, duration REAL, axis_corr REAL);
CREATE TABLE IF NOT EXISTS samples (
  id INTEGER PRIMARY KEY, t REAL, clip TEXT, speed REAL, pedal REAL, steering REAL,
  brake INTEGER, blinker_left INTEGER, blinker_right INTEGER, gear TEXT, autopilot TEXT,
  lat REAL, lon REAL, heading REAL, accel_long REAL, accel_lat REAL, accel_z REAL);
CREATE INDEX IF NOT EXISTS samples_t ON samples (t);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, type TEXT, start_t REAL, end_t REAL, peak REAL,
  speed_start REAL, speed_end REAL, lat REAL, lon REAL, heading REAL, clip TEXT, offset_s REAL,
  alert_state TEXT, alert_attempts INTEGER DEFAULT 0, alert_next_at REAL DEFAULT 0);
CREATE INDEX IF NOT EXISTS events_t ON events (start_t);
CREATE INDEX IF NOT EXISTS events_alert ON events (alert_state);
"""


def open_db(path=DB_PATH):
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db(path=DB_PATH):
    conn = open_db(path)
    conn.executescript(SCHEMA)
    conn.commit()
    # The API runs as its own user, and owns the data directory.
    if os.geteuid() == 0:
        owner = os.stat(os.path.dirname(path))
        os.chown(path, owner.st_uid, owner.st_gid)
    return conn


def meta_get(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def meta_set(conn, key, value):
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, str(value)))


def _stored_rows(name, start, samples):
    next_at = 0.0
    for s in samples:
        if s["offset"] < next_at:
            continue
        next_at = s["offset"] + 1 / STORE_HZ
        yield (
            round(start + s["offset"], 3), name, round(s["speed"], 3), round(s["pedal"], 2),
            round(s["steering"], 2), int(s["brake"]), int(s["blinker_left"]), int(s["blinker_right"]),
            GEARS.get(s["gear"], "unknown"), AUTOPILOT.get(s["autopilot"], "unknown"),
            round(s["lat"], 7), round(s["lon"], 7), round(s["heading"], 2),
            round(s["accel_long"], 3), round(s["accel_lat"], 3), round(s["accel_z"], 3),
        )


def store_clip(conn, name, clip, cfg, alert):
    """Store one clip and move the watermark, all or nothing. Returns the new events."""
    start = clip_start(name)
    samples = clip["samples"]
    corr = axis_correlation(clip)
    added = []
    with conn:
        conn.execute(
            "INSERT OR REPLACE INTO clips VALUES (?, ?, ?, 'parsed', ?, ?, ?)",
            (name, start, time.time(), len(samples), clip["duration"], corr),
        )
        conn.executemany(
            "INSERT INTO samples (t, clip, speed, pedal, steering, brake, blinker_left, blinker_right,"
            " gear, autopilot, lat, lon, heading, accel_long, accel_lat, accel_z)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            _stored_rows(name, start, samples),
        )
        for event in detect_events(clip, cfg):
            begin = start + event["offset_start"]
            # An event can straddle two clips.
            prior = conn.execute(
                "SELECT 1 FROM events WHERE type = ? AND end_t >= ? LIMIT 1",
                (event["type"], begin - MERGE_SECS),
            ).fetchone()
            if prior:
                continue
            state = "pending" if alert and cfg.get("webhook_url") else "none"
            conn.execute(
                "INSERT INTO events (type, start_t, end_t, peak, speed_start, speed_end, lat, lon, heading,"
                " clip, offset_s, alert_state) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (event["type"], round(begin, 3), round(start + event["offset_end"], 3), event["peak"],
                 event["speed_start"], event["speed_end"], round(event["lat"], 7), round(event["lon"], 7),
                 round(event["heading"], 2), name, round(event["offset_start"], 3), state),
            )
            added.append(event)
        meta_set(conn, "watermark", name)
        if corr is not None:
            meta_set(conn, "axis_corr", corr)
    return added


def skip_clip(conn, name):
    with conn:
        conn.execute(
            "INSERT OR REPLACE INTO clips VALUES (?, ?, ?, 'unfinished', 0, 0, NULL)",
            (name, clip_start(name), time.time()),
        )
        meta_set(conn, "watermark", name)


def prune(conn, keep_days):
    """Age by the newest sample, because a Pi with no network can have the wrong time."""
    newest = conn.execute("SELECT max(t) AS t FROM samples").fetchone()["t"]
    if newest is None:
        return
    cutoff = newest - keep_days * 86400
    with conn:
        conn.execute("DELETE FROM samples WHERE t < ?", (cutoff,))
        conn.execute("DELETE FROM events WHERE start_t < ?", (cutoff,))
        conn.execute("DELETE FROM clips WHERE start_t < ?", (cutoff,))


# --- reading the drive -----------------------------------------------------


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)


@contextlib.contextmanager
def locked():
    """The same lock the shell scripts take. Yields False while one of them holds it."""
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    with open(LOCK_PATH, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def origin_exists():
    return os.path.exists(ORIGIN)


def flush_and_read_sectors():
    """Push the car's cached writes to the disk, then return the sectors written so far.

    The gadget writes through the page cache. A view that reads the disk would
    otherwise lag by up to 30 seconds. The descriptor is closed again right
    away, so it can never hold up storage teardown.
    """
    fd = os.open(ORIGIN, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    name = os.path.basename(os.path.realpath(ORIGIN))
    with open(f"/sys/block/{name}/stat") as stat:
        return int(stat.read().split()[6])


def origin_extent():
    """(start, length) in sectors of the first partition, or the whole disk without one."""
    listing = run("kpartx", "-l", ORIGIN).stdout
    for line in listing.splitlines():
        match = re.match(r"^\S+ : \d+ (\d+) \S+ (\d+)$", line.strip())
        if match:
            return int(match.group(2)), int(match.group(1))
    return 0, int(run("blockdev", "--getsz", ORIGIN).stdout.strip())


def clear_stale_view():
    subprocess.run(["umount", VIEW_MOUNT], capture_output=True, timeout=30)
    subprocess.run(["dmsetup", "remove", VIEW_NAME], capture_output=True, timeout=30)


@contextlib.contextmanager
def drive_view():
    """A private, read-only view of the drive with its own cache.

    The kernel refuses every write to a --readonly device. A new device for each
    scan means no stale directory entries, whichever SHARE mode is in use and
    even while an SMB client is connected.
    """
    clear_stale_view()
    start, length = origin_extent()
    run("dmsetup", "create", VIEW_NAME, "--readonly", "--table", f"0 {length} linear {ORIGIN} {start}")
    try:
        fstype = run("blkid", "-p", "-o", "value", "-s", "TYPE", VIEW_DEV).stdout.strip()
        if fstype == "ext4":
            # noload: replaying the journal would be a write to the car's disk.
            options = "ro,noatime,noload"
        elif fstype in ("exfat", "vfat"):
            options = "ro,noatime,umask=022"
        else:
            raise RuntimeError(f"unrecognized filesystem {fstype or 'unknown'}")
        os.makedirs(VIEW_MOUNT, exist_ok=True)
        run("mount", "-t", fstype, "-o", options, VIEW_DEV, VIEW_MOUNT)
        try:
            yield VIEW_MOUNT
        finally:
            if subprocess.run(["umount", VIEW_MOUNT], capture_output=True, timeout=30).returncode:
                subprocess.run(["umount", "-l", VIEW_MOUNT], capture_output=True, timeout=30)
    finally:
        subprocess.run(["dmsetup", "remove", VIEW_NAME], capture_output=True, timeout=30)


def list_front_clips(root):
    try:
        names = os.listdir(os.path.join(root, CLIPS_DIR))
    except FileNotFoundError:
        return []
    return sorted(name for name in names if FRONT_CLIP.match(name))


def count_encrypted(root):
    try:
        return len(os.listdir(os.path.join(root, ENCRYPTED_DIR)))
    except OSError:
        return 0


class Scanner:
    def __init__(self, conn, cfg, view=drive_view, lock=locked, exists=origin_exists,
                 sectors=flush_and_read_sectors):
        self.conn = conn
        self.cfg = cfg
        self.view = view
        self.lock = lock
        self.exists = exists
        self.sectors = sectors
        self.last_sectors = None
        self.retry = False
        self.attempts = {}
        self.stored = 0

    def tick(self):
        """One pass. True means there is more to do right away."""
        with self.lock() as held:
            if not held or not self.exists():
                return False
            sectors = self.sectors()
            if sectors == self.last_sectors and not self.retry:
                return False
            with self.view() as root:
                more = self.process(root)
            self.last_sectors = sectors
            return more

    def process(self, root):
        names = list_front_clips(root)
        watermark = meta_get(self.conn, "watermark")
        first_run = watermark is None
        new = [name for name in names if first_run or name > watermark]
        if first_run:
            new = new[-2:]  # Just enough for /latest to answer. Old drives stay out of it.
        self.retry = False
        batch = new[:MAX_BATCH]
        for index, name in enumerate(batch):
            clip = self.read(root, name)
            if clip is None:
                limit = RETRY_NEWEST if name == new[-1] else RETRY_OLDER
                self.attempts[name] = self.attempts.get(name, 0) + 1
                if self.attempts[name] < limit:
                    self.retry = True
                    break
                skip_clip(self.conn, name)
                self.attempts.pop(name, None)
                continue
            self.attempts.pop(name, None)
            alert = not first_run and index >= len(new) - ALERT_NEWEST
            for event in store_clip(self.conn, name, clip, self.cfg, alert):
                say(f"{event['type']} {event['peak']:.1f} m/s2 in {name}")
            self.stored += 1
            if self.stored % 60 == 0:
                prune(self.conn, self.cfg["keep_days"])
        with self.conn:
            meta_set(self.conn, "last_scan_at", time.time())
            meta_set(self.conn, "encrypted_recent", count_encrypted(root))
        backlog = not self.retry and len(new) > len(batch)
        self.retry = self.retry or backlog  # The rest needs no new writes to be read.
        return backlog

    @staticmethod
    def read(root, name):
        try:
            return read_clip(os.path.join(root, CLIPS_DIR, name))
        except (OSError, struct.error):
            return None  # The car can be changing the filesystem under this view.


# --- API and alerts --------------------------------------------------------


def row_dict(row):
    return {key: row[key] for key in row.keys()}


def event_public(row):
    event = row_dict(row)
    for key in ("alert_attempts", "alert_next_at"):
        event.pop(key, None)
    return event


def fetch_samples(conn, query):
    since = float(query.get("since", 0))
    limit = max(1, min(int(query.get("limit", 1000)), MAX_ROWS))
    rows = conn.execute("SELECT * FROM samples WHERE t > ? ORDER BY t LIMIT ?", (since, limit)).fetchall()
    return [row_dict(row) for row in rows]


def fetch_events(conn, query):
    since = float(query.get("since", 0))
    limit = max(1, min(int(query.get("limit", 200)), MAX_ROWS))
    kind = query.get("type")
    sql = "SELECT * FROM events WHERE start_t > ?"
    args = [since]
    if kind:
        sql += " AND type = ?"
        args.append(kind)
    rows = conn.execute(sql + " ORDER BY start_t DESC LIMIT ?", (*args, limit)).fetchall()
    return [event_public(row) for row in rows]


def fetch_status(conn):
    clip = conn.execute("SELECT * FROM clips WHERE status = 'parsed' ORDER BY name DESC LIMIT 1").fetchone()
    counts = {
        table: conn.execute(f"SELECT count(*) AS n FROM {table}").fetchone()["n"]
        for table in ("clips", "samples", "events")
    }
    last_scan = meta_get(conn, "last_scan_at")
    corr = meta_get(conn, "axis_corr")
    return {
        "last_clip": clip["name"] if clip else None,
        "last_clip_sei": clip["sei_count"] if clip else None,
        "last_scan_at": float(last_scan) if last_scan else None,
        "axis_correlation": float(corr) if corr else None,
        "encrypted_recent": int(meta_get(conn, "encrypted_recent") or 0),
        "pending_alerts": conn.execute(
            "SELECT count(*) AS n FROM events WHERE alert_state = 'pending'").fetchone()["n"],
        **counts,
    }


class Api(BaseHTTPRequestHandler):
    server_version = "dashcam-telemetry"
    sys_version = ""
    timeout = 30

    def log_message(self, *args):
        pass  # A request log would be steady writes to the SD card, with no use.

    def reply(self, code, body, extra=()):
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        supplied = self.headers.get("Authorization", "")
        wanted = "Bearer " + self.server.cfg["token"]
        return hmac.compare_digest(supplied.encode(), wanted.encode())

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/healthz":
            self.reply(200, {"ok": True})
            return
        if not self.authorized():
            self.reply(401, {"error": "unauthorized"}, [("WWW-Authenticate", "Bearer")])
            return
        query = dict(urllib.parse.parse_qsl(url.query))
        routes = {
            "/latest": self.latest,
            "/samples": lambda conn: self.reply(200, fetch_samples(conn, query)),
            "/events": lambda conn: self.reply(200, fetch_events(conn, query)),
            "/status": lambda conn: self.reply(200, fetch_status(conn)),
            "/stream": self.stream,
        }
        route = routes.get(url.path)
        if route is None:
            self.reply(404, {"error": "not found"})
            return
        conn = open_db(self.server.db_path)
        try:
            route(conn)
        except ValueError:
            self.reply(400, {"error": "bad query"})
        except (BrokenPipeError, ConnectionError, TimeoutError):
            pass
        finally:
            conn.close()

    def latest(self, conn):
        row = conn.execute("SELECT * FROM samples ORDER BY t DESC LIMIT 1").fetchone()
        if row is None:
            self.reply(404, {"error": "no samples yet"})
        else:
            self.reply(200, row_dict(row))

    def stream(self, conn):
        """Server-sent events. Rows arrive in a burst as each clip is finished."""
        if not self.server.streams.acquire(blocking=False):
            self.reply(503, {"error": "too many streams"})
            return
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            last_sample = conn.execute("SELECT coalesce(max(id), 0) AS n FROM samples").fetchone()["n"]
            last_event = conn.execute("SELECT coalesce(max(id), 0) AS n FROM events").fetchone()["n"]
            idle = 0.0
            while not self.server.stop.is_set():
                samples = conn.execute(
                    "SELECT * FROM samples WHERE id > ? ORDER BY id LIMIT 500", (last_sample,)).fetchall()
                events = conn.execute(
                    "SELECT * FROM events WHERE id > ? ORDER BY id LIMIT 50", (last_event,)).fetchall()
                for row in samples:
                    self.wfile.write(f"event: sample\ndata: {json.dumps(row_dict(row))}\n\n".encode())
                    last_sample = row["id"]
                for row in events:
                    self.wfile.write(f"event: alert\ndata: {json.dumps(event_public(row))}\n\n".encode())
                    last_event = row["id"]
                if samples or events:
                    self.wfile.flush()
                    idle = 0.0
                    continue
                idle += 1.0
                if idle >= 15:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    idle = 0.0
                self.server.stop.wait(1.0)
        finally:
            self.server.streams.release()


def event_message(event):
    label = LABELS.get(event["type"], event["type"])
    moment = time.strftime("%H:%M:%S", time.localtime(event["start_t"]))
    mph = event["speed_start"] * 2.23694
    kmh = event["speed_start"] * 3.6
    return f"{label}: {event['peak']:.1f} m/s² ({event['peak'] / 9.80665:.2f} g) at {moment}, {mph:.0f} mph ({kmh:.0f} km/h)"


def alert_request(event, cfg):
    """Third-party services see only what is here, so GPS stays out unless asked for."""
    message = event_message(event)
    if cfg["webhook_format"] == "text":
        return message.encode(), "text/plain; charset=utf-8"
    detail = {key: event[key] for key in ("type", "start_t", "end_t", "peak", "speed_start", "speed_end", "clip", "offset_s")}
    if cfg["webhook_gps"]:
        detail.update(lat=event["lat"], lon=event["lon"], heading=event["heading"])
    body = {"content": message, "text": message, "message": message, "event": detail}
    return json.dumps(body).encode(), "application/json"


def post_alert(event, cfg):
    data, content_type = alert_request(event, cfg)
    request = urllib.request.Request(cfg["webhook_url"], data=data, headers={"Content-Type": content_type}, method="POST")
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read(1024)


def send_alerts(conn, cfg, post=post_alert, now=time.time):
    """Send whatever is due. The car is often offline, so failures wait and retry."""
    rows = conn.execute(
        "SELECT * FROM events WHERE alert_state = 'pending' AND alert_next_at <= ? ORDER BY start_t LIMIT 10",
        (now(),),
    ).fetchall()
    for row in rows:
        event = row_dict(row)
        try:
            post(event, cfg)
        except Exception as error:  # pylint: disable=broad-except
            attempts = event["alert_attempts"] + 1
            state = "failed" if attempts >= ALERT_MAX_ATTEMPTS else "pending"
            delay = min(3600, 30 * 2 ** min(attempts, 10))
            with conn:
                conn.execute(
                    "UPDATE events SET alert_state = ?, alert_attempts = ?, alert_next_at = ? WHERE id = ?",
                    (state, attempts, now() + delay, event["id"]),
                )
            # The URL can hold a secret, so only the kind of failure is logged.
            say(f"alert {event['id']} not sent yet ({type(error).__name__})")
            return
        with conn:
            conn.execute("UPDATE events SET alert_state = 'sent' WHERE id = ?", (event["id"],))


def alert_loop(cfg, db_path, stop):
    conn = open_db(db_path)
    while not stop.is_set():
        with contextlib.suppress(sqlite3.Error):
            send_alerts(conn, cfg)
        stop.wait(5)
    conn.close()


def make_server(cfg, db_path):
    server = ThreadingHTTPServer((cfg["bind"], cfg["port"]), Api)
    server.daemon_threads = True
    server.cfg = cfg
    server.db_path = db_path
    server.stop = threading.Event()
    server.streams = threading.BoundedSemaphore(MAX_STREAMS)
    return server


# --- write timing ----------------------------------------------------------


def summarize_write_log(rows):
    """rows are (monotonic seconds, sectors written). Each is a second with writes."""
    if len(rows) < 2:
        return None
    gaps = [b[0] - a[0] for a, b in zip(rows, rows[1:]) if b[0] - a[0] <= 600]
    if not gaps:
        return None
    gaps.sort()
    bursts = sorted(row[1] * 512 / 1e6 for row in rows)
    p95 = gaps[min(len(gaps) - 1, int(len(gaps) * 0.95))]
    if p95 <= 5:
        verdict = "The car streams to the drive, so reading the disk as it writes is worth building."
    elif p95 <= 20:
        verdict = "The car writes in bursts, so reading the disk as it writes would gain some time."
    else:
        verdict = "The car holds data back for a long time, so reading the disk as it writes would gain little."
    return {
        "seconds_with_writes": len(rows),
        "total_mb": round(sum(bursts), 1),
        "median_gap_s": round(statistics.median(gaps), 1),
        "p95_gap_s": round(p95, 1),
        "max_gap_s": round(gaps[-1], 1),
        "median_burst_mb": round(statistics.median(bursts), 2),
        "verdict": verdict,
    }


def read_write_log(path):
    rows = []
    with open(path) as handle:
        next(handle, None)
        for line in handle:
            with contextlib.suppress(ValueError):
                clock, sectors = line.strip().split(",")
                rows.append((float(clock), int(sectors)))
    return rows


def write_log_main(stop, directory=DATA_DIR):
    path = os.path.join(directory, time.strftime("write-timing-%Y%m%d-%H%M%S.csv"))
    for old in sorted(glob.glob(os.path.join(directory, "write-timing-*.csv")))[:-(WRITE_LOG_KEEP - 1)]:
        with contextlib.suppress(OSError):
            os.unlink(old)
    previous = None
    active = 0
    buffered = []
    last_flush = time.monotonic()

    def flush(handle):
        handle.writelines(buffered)
        handle.flush()
        buffered.clear()

    with open(path, "w") as handle:
        handle.write("monotonic_s,sectors\n")
        while not stop.is_set() and active < WRITE_LOG_ACTIVE_SECS:
            with locked() as held:
                if held and origin_exists():
                    sectors = flush_and_read_sectors()
                    if previous is not None and sectors > previous:
                        buffered.append(f"{time.monotonic():.2f},{sectors - previous}\n")
                        active += 1
                    previous = sectors
            if time.monotonic() - last_flush >= 30:
                flush(handle)
                last_flush = time.monotonic()
            stop.wait(1)
        flush(handle)
    say(f"write log finished: {active} seconds with writes in {path}")


def write_report_main(directory=DATA_DIR):
    logs = sorted(glob.glob(os.path.join(directory, "write-timing-*.csv")))
    if not logs:
        say("no write log yet. Set TELEMETRY_WRITE_LOG=1, run provision, reboot, and drive.")
        return 1
    summary = summarize_write_log(read_write_log(logs[-1]))
    if summary is None:
        say(f"{logs[-1]} has too little data. Was the car driving and writing?")
        return 1
    say(os.path.basename(logs[-1]))
    for key, value in summary.items():
        say(f"{key}: {value}")
    return 0


# --- commands --------------------------------------------------------------


def config_from_env(env):
    return {
        "port": int(env.get("TELEMETRY_PORT", "8088")),
        "bind": env.get("TELEMETRY_BIND", "0.0.0.0"),
        "token": env["TELEMETRY_TOKEN"],
        "poll_secs": int(env.get("TELEMETRY_POLL_SECS", "10")),
        "brake_mps2": float(env.get("TELEMETRY_BRAKE_MPS2", "4")),
        "accel_mps2": float(env.get("TELEMETRY_ACCEL_MPS2", "4")),
        "corner_mps2": float(env.get("TELEMETRY_CORNER_MPS2", "4")),
        "hold_ms": int(env.get("TELEMETRY_HOLD_MS", "250")),
        "keep_days": int(env.get("TELEMETRY_KEEP_DAYS", "30")),
        "webhook_url": env.get("TELEMETRY_WEBHOOK_URL", ""),
        "webhook_format": env.get("TELEMETRY_WEBHOOK_FORMAT", "json"),
        "webhook_gps": env.get("TELEMETRY_WEBHOOK_GPS", "0") == "1",
    }


def load_config(path=CONFIG_PATH):
    with open(path) as handle:
        return json.load(handle)


def write_config(path, owner_group):
    cfg = config_from_env(os.environ)
    temporary = path + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(cfg, handle, indent=2)
        handle.write("\n")
    if owner_group is not None:
        import grp  # Only needed on the Pi.
        os.chown(temporary, 0, grp.getgrnam(owner_group).gr_gid)
    os.chmod(temporary, 0o640)
    os.replace(temporary, path)


def stop_event():
    stop = threading.Event()
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, lambda *_: stop.set())
    return stop


def scan_main(cfg):
    stop = stop_event()
    conn = init_db()
    scanner = Scanner(conn, cfg)
    say("telemetry scanner started")
    failing = False
    try:
        while not stop.is_set():
            more = False
            try:
                more = scanner.tick()
                failing = False
            except (OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
                # Say it once. A drive that stays broken must not fill the journal.
                if not failing:
                    say(f"telemetry scan failed: {error}")
                failing = True
            if not more:
                stop.wait(cfg["poll_secs"])
    finally:
        conn.close()
        clear_stale_view()


def serve_main(cfg):
    stop = stop_event()
    init_db().close()
    server = make_server(cfg, DB_PATH)
    server.stop = stop
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if cfg.get("webhook_url"):
        threading.Thread(target=alert_loop, args=(cfg, DB_PATH, stop), daemon=True).start()
    say(f"telemetry API on {cfg['bind']}:{cfg['port']}")
    stop.wait()
    server.shutdown()


def check_main(paths):
    cfg = {"brake_mps2": 4.0, "accel_mps2": 4.0, "corner_mps2": 4.0, "hold_ms": 250}
    for path in paths:
        clip = read_clip(path)
        if clip is None:
            say(f"{os.path.basename(path)}: unfinished")
            continue
        samples = clip["samples"]
        if not samples:
            say(f"{os.path.basename(path)}: no SEI")
            continue
        speeds = [s["speed"] for s in samples]
        longs = [s["accel_long"] for s in samples]
        found = [f"{e['type']}@{e['offset_start']:.0f}s:{e['peak']:.1f}" for e in detect_events(clip, cfg)]
        say(f"{os.path.basename(path)}: sei={len(samples)} dur={clip['duration']:.1f}s"
            f" speed={min(speeds):.1f}-{max(speeds):.1f} long={min(longs):.2f}..{max(longs):.2f}"
            f" axis_corr={axis_correlation(clip)} events={found}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("scan")
    commands.add_parser("serve")
    commands.add_parser("write-log")
    commands.add_parser("write-report")
    check = commands.add_parser("check")
    check.add_argument("paths", nargs="+")
    writer = commands.add_parser("write-config")
    writer.add_argument("path")
    writer.add_argument("group")
    args = parser.parse_args(argv)
    if args.command == "scan":
        scan_main(load_config())
    elif args.command == "serve":
        serve_main(load_config())
    elif args.command == "write-log":
        write_log_main(stop_event())
    elif args.command == "write-report":
        return write_report_main()
    elif args.command == "check":
        return check_main(args.paths)
    elif args.command == "write-config":
        write_config(args.path, args.group)
    return 0


if __name__ == "__main__":
    sys.exit(main())
