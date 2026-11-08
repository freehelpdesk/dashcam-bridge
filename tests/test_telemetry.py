#!/usr/bin/env python3
"""Tests for scripts/telemetry.py. Synthetic clips, and no Pi or root needed."""
import contextlib
import datetime
import http.client
import importlib.util
import io
import json
import os
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

SCRIPTS = os.environ.get("SCRIPTS") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("telemetry", os.path.join(SCRIPTS, "telemetry.py"))
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)

CFG = {
    "port": 0, "bind": "127.0.0.1", "token": "test-token-1234567890", "poll_secs": 10,
    "brake_mps2": 4.0, "accel_mps2": 4.0, "corner_mps2": 4.0, "hold_ms": 250, "keep_days": 30,
    "webhook_url": "https://example.invalid/hook", "webhook_format": "json", "webhook_gps": False,
}
HZ = 36


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def field(number, wire, payload):
    return varint((number << 3) | wire) + payload


def proto(speed=0.0, forward=0.0, side=0.0, brake=False, gear=1, lat=None):
    data = field(1, 0, varint(1)) + field(2, 0, varint(gear))
    if speed:
        data += field(4, 5, struct.pack("<f", speed))
    if brake:
        data += field(9, 0, varint(1))
    if lat is not None:
        data += field(11, 1, struct.pack("<d", lat)) + field(12, 1, struct.pack("<d", -lat))
    if side:
        data += field(14, 1, struct.pack("<d", side))
    if forward:
        data += field(15, 1, struct.pack("<d", -forward))  # This car's forward is -y.
    return data


def escape(data):
    out = bytearray()
    zeros = 0
    for byte in data:
        if zeros >= 2 and byte <= 3:
            out.append(3)
            zeros = 0
        out.append(byte)
        zeros = 0 if byte else zeros + 1
    return bytes(out)


def sei_nal(payload):
    return b"\x06\x05\x20\x42\x42\x69" + escape(payload) + b"\x80"


def atom(kind, body):
    return struct.pack(">I4s", 8 + len(body), kind) + body


def mvhd(duration):
    return atom(b"mvhd", b"\0" * 4 + b"\0" * 8 + struct.pack(">II", 1000, int(duration * 1000)) + b"\0" * 80)


def mp4(payloads, duration=60.0, finished=True):
    media = bytearray()
    for payload in payloads:
        nal = sei_nal(payload)
        media += struct.pack(">I", len(nal)) + nal
        frame = b"\x41\x9a" + b"\xaa" * 40
        media += struct.pack(">I", len(frame)) + frame
    head = atom(b"ftyp", b"mp42" + b"\0" * 4) + atom(b"free", b"")
    if not finished:
        return head + struct.pack(">I4s", 0, b"mdat") + bytes(media)
    return head + atom(b"mdat", bytes(media)) + atom(b"moov", mvhd(duration))


def driving(shape, duration=60.0):
    """shape(t) -> (speed, forward, side)."""
    out = []
    for i in range(int(duration * HZ)):
        speed, forward, side = shape(i / HZ)
        out.append(proto(speed=speed, forward=forward, side=side, lat=37.5))
    return out


def cruise(_):
    return 20.0, 0.0, 0.0


def brake_shape(start, length, force=6.0, v0=25.0):
    def shape(t):
        if t < start:
            return v0, 0.0, 0.0
        if t < start + length:
            return v0 - force * (t - start), -force, 0.0
        return v0 - force * length, 0.0, 0.0
    return shape


def clip_from(shape, duration=60.0):
    with tempfile.NamedTemporaryFile(suffix=".mp4") as handle:
        handle.write(mp4(driving(shape, duration), duration))
        handle.flush()
        return telemetry.read_clip(handle.name)


def name_at(minute):
    moment = datetime.datetime(2026, 11, 7, 18, 0, 0) + datetime.timedelta(minutes=minute)
    return moment.strftime("%Y-%m-%d_%H-%M-%S-front.mp4")


class Parsing(unittest.TestCase):
    def test_fields_and_axis(self):
        sample = telemetry.decode_sample(proto(speed=12.5, forward=3.0, side=-1.5, brake=True, lat=37.5))
        self.assertAlmostEqual(sample["speed"], 12.5)
        self.assertAlmostEqual(sample["accel_long"], 3.0)
        self.assertAlmostEqual(sample["accel_lat"], -1.5)
        self.assertTrue(sample["brake"])
        self.assertAlmostEqual(sample["lat"], 37.5)

    def test_absent_fields_are_zero(self):
        sample = telemetry.decode_sample(b"")
        self.assertEqual((sample["speed"], sample["gear"], sample["brake"]), (0.0, 0, False))

    def test_truncated_protobuf_is_refused(self):
        with self.assertRaises((ValueError, IndexError)):
            telemetry.parse_protobuf(field(4, 5, b"\x01"))

    def test_emulation_prevention_is_removed(self):
        # Two zero bytes and then a small one are what force the escape.
        value = struct.unpack("<d", b"\x00\x00\x01\x00\x00\x00\xf0\x3f")[0]
        nal = sei_nal(proto(lat=value))
        self.assertIn(b"\0\0\x03\x01", nal)
        self.assertEqual(telemetry.decode_sample(telemetry.sei_payload(nal))["lat"], value)

    def write(self, data):
        handle = tempfile.NamedTemporaryFile(suffix=".mp4", delete=False)
        handle.write(data)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_reads_a_finished_clip(self):
        clip = telemetry.read_clip(self.write(mp4([proto(speed=5.0)] * 3, 30.0)))
        self.assertEqual(len(clip["samples"]), 3)
        self.assertAlmostEqual(clip["duration"], 30.0)
        self.assertAlmostEqual(clip["samples"][2]["offset"], 20.0)

    def test_no_sei_is_finished_and_empty(self):
        self.assertEqual(telemetry.read_clip(self.write(mp4([])))["samples"], [])

    def test_unfinished_clips_wait(self):
        whole = mp4([proto(speed=5.0)] * 3)
        self.assertIsNone(telemetry.read_clip(self.write(mp4([proto()], finished=False))))
        self.assertIsNone(telemetry.read_clip(self.write(whole[:-20])))

    def test_zeroed_media_waits(self):
        body = atom(b"mdat", b"\0" * 400)
        self.assertIsNone(telemetry.read_clip(self.write(atom(b"ftyp", b"mp42") + body + atom(b"moov", mvhd(60)))))

    def test_nal_past_the_end_waits(self):
        body = atom(b"mdat", struct.pack(">I", 9999) + b"\x06\x05")
        self.assertIsNone(telemetry.read_clip(self.write(atom(b"ftyp", b"mp42") + body + atom(b"moov", mvhd(60)))))


class Detection(unittest.TestCase):
    def kinds(self, shape):
        return [e["type"] for e in telemetry.detect_events(clip_from(shape), CFG)]

    def test_cruising_is_quiet(self):
        self.assertEqual(self.kinds(cruise), [])

    def test_hard_brake(self):
        events = telemetry.detect_events(clip_from(brake_shape(10, 2.0)), CFG)
        self.assertEqual([e["type"] for e in events], ["hard_brake"])
        self.assertAlmostEqual(events[0]["peak"], 6.0, places=1)
        self.assertAlmostEqual(events[0]["offset_start"], 10.0, delta=0.2)
        self.assertLess(events[0]["speed_end"], events[0]["speed_start"])

    def test_hard_accel(self):
        def shape(t):
            return (5.0 + 5.0 * (t - 10), 5.0, 0.0) if 10 <= t < 12 else ((5.0 if t < 10 else 15.0), 0.0, 0.0)
        self.assertEqual(self.kinds(shape), ["hard_accel"])

    def test_corner_in_either_direction(self):
        for side in (5.0, -5.0):
            self.assertEqual(self.kinds(lambda t, s=side: (15.0, 0.0, s if 5 <= t < 7 else 0.0)), ["hard_corner"])

    def test_too_brief_is_ignored(self):
        self.assertEqual(self.kinds(brake_shape(10, 0.1)), [])

    def test_below_threshold_is_ignored(self):
        self.assertEqual(self.kinds(brake_shape(10, 2.0, force=3.0)), [])

    def test_pothole_without_speed_change_is_ignored(self):
        self.assertEqual(self.kinds(lambda t: (20.0, -8.0 if 10 <= t < 10.6 else 0.0, 0.0)), [])

    def test_stationary_jolt_is_ignored(self):
        self.assertEqual(self.kinds(lambda t: (0.0, -8.0 if 10 <= t < 11 else 0.0, 0.0)), [])

    def test_two_stabs_close_together_are_one_event(self):
        def shape(t):
            if 10 <= t < 11:
                return 25.0 - 6.0 * (t - 10), -6.0, 0.0
            if 11 <= t < 12:
                return 19.0, 0.0, 0.0
            if 12 <= t < 13:
                return 19.0 - 6.0 * (t - 12), -6.0, 0.0
            return (25.0 if t < 10 else 13.0), 0.0, 0.0
        self.assertEqual(self.kinds(shape), ["hard_brake"])

    def test_axis_correlation_near_one_for_this_car(self):
        def shape(t):
            phase = int(t / 5) % 2
            force = 2.0 if phase == 0 else -2.0
            base = 10 + 2.0 * (t % 5) if phase == 0 else 20 - 2.0 * (t % 5)
            return base, force, 0.0
        self.assertGreater(telemetry.axis_correlation(clip_from(shape)), 0.8)

    def test_axis_correlation_abstains_at_steady_speed(self):
        self.assertIsNone(telemetry.axis_correlation(clip_from(cruise)))


class ScannerBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.clips = os.path.join(self.root, telemetry.CLIPS_DIR)
        os.makedirs(self.clips)
        self.conn = telemetry.init_db(os.path.join(self.root, "t.db"))
        self.addCleanup(self.conn.close)
        self.writes = 1
        self.views = 0
        self.held = True
        self.scanner = telemetry.Scanner(
            self.conn, CFG, view=self.view, lock=self.lock, exists=lambda: True, sectors=lambda: self.writes)
        output = contextlib.redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)

    @contextlib.contextmanager
    def view(self):
        self.views += 1
        yield self.root

    @contextlib.contextmanager
    def lock(self):
        yield self.held

    def add(self, minute, shape=cruise, finished=True, duration=60.0):
        data = mp4(driving(shape, duration), duration, finished=finished)
        with open(os.path.join(self.clips, name_at(minute)), "wb") as handle:
            handle.write(data)
        self.writes += 1

    def start(self):
        self.add(0)
        self.scanner.tick()

    def events(self):
        return self.conn.execute("SELECT * FROM events ORDER BY start_t").fetchall()

    def watermark(self):
        return telemetry.meta_get(self.conn, "watermark")


class Scanning(ScannerBase):
    def test_first_run_takes_only_the_newest_and_stays_quiet(self):
        for minute in range(5):
            self.add(minute, brake_shape(10, 2.0))
        self.scanner.tick()
        self.assertEqual(self.conn.execute("SELECT count(*) AS n FROM clips").fetchone()["n"], 2)
        self.assertEqual({row["alert_state"] for row in self.events()}, {"none"})

    def test_new_clip_is_stored_and_alerts(self):
        self.start()
        self.add(1, brake_shape(10, 2.0))
        self.scanner.tick()
        self.assertEqual(self.watermark(), name_at(1))
        self.assertEqual([row["alert_state"] for row in self.events()], ["pending"])

    def test_no_webhook_means_no_pending_alert(self):
        self.scanner.cfg = dict(CFG, webhook_url="")
        self.start()
        self.add(1, brake_shape(10, 2.0))
        self.scanner.tick()
        self.assertEqual(self.events()[0]["alert_state"], "none")

    def test_samples_are_thinned_but_detection_is_not(self):
        self.start()
        before = self.conn.execute("SELECT count(*) AS n FROM samples").fetchone()["n"]
        self.add(1, brake_shape(10, 0.4))
        self.scanner.tick()
        added = self.conn.execute("SELECT count(*) AS n FROM samples").fetchone()["n"] - before
        self.assertAlmostEqual(added, 120, delta=2)
        self.assertEqual(len(self.events()), 1)

    def test_idle_disk_does_not_scan(self):
        self.start()
        views = self.views
        self.scanner.tick()
        self.assertEqual(self.views, views)

    def test_lock_held_elsewhere_does_nothing(self):
        self.held = False
        self.add(0)
        self.assertFalse(self.scanner.tick())
        self.assertEqual(self.views, 0)

    def test_macos_sidecars_and_other_cameras_are_ignored(self):
        self.start()
        for name in ("._" + name_at(1), name_at(1).replace("front", "back")):
            with open(os.path.join(self.clips, name), "wb") as handle:
                handle.write(b"junk")
        self.writes += 1
        self.scanner.tick()
        self.assertEqual(self.watermark(), name_at(0))

    def test_recording_clip_is_retried_without_new_writes(self):
        self.start()
        self.add(1, finished=False)
        self.scanner.tick()
        self.assertEqual(self.watermark(), name_at(0))
        self.add(1)
        self.writes -= 1  # The car finished before the last flush.
        self.scanner.tick()
        self.assertEqual(self.watermark(), name_at(1))

    def test_newest_clip_is_eventually_given_up_on(self):
        self.start()
        self.add(1, finished=False)
        for _ in range(telemetry.RETRY_NEWEST):
            self.writes += 1
            self.scanner.tick()
        self.assertEqual(self.watermark(), name_at(1))
        status = self.conn.execute("SELECT status FROM clips WHERE name = ?", (name_at(1),)).fetchone()["status"]
        self.assertEqual(status, "unfinished")

    def test_broken_clip_does_not_hold_up_newer_ones_for_long(self):
        self.start()
        self.add(1, finished=False)
        self.add(2)
        for _ in range(telemetry.RETRY_OLDER):
            self.writes += 1
            self.scanner.tick()
        self.assertEqual(self.watermark(), name_at(2))

    def test_backlog_is_batched_and_only_the_newest_alert(self):
        self.start()
        count = telemetry.MAX_BATCH + 3
        for minute in range(1, count + 1):
            self.add(minute, brake_shape(10, 2.0))
        self.assertTrue(self.scanner.tick())
        self.assertEqual(self.watermark(), name_at(telemetry.MAX_BATCH))
        while self.scanner.tick():
            pass
        states = [row["alert_state"] for row in self.events()]
        self.assertEqual(len(states), count)
        # The batch boundary recalculates the backlog, so only the tail may alert.
        self.assertEqual(states[:telemetry.MAX_BATCH - telemetry.ALERT_NEWEST], ["none"] * (telemetry.MAX_BATCH - telemetry.ALERT_NEWEST))
        self.assertEqual(states[-1], "pending")

    def test_event_across_a_clip_boundary_is_one_event(self):
        self.start()
        self.add(1, brake_shape(58, 2.0))
        self.scanner.tick()
        self.add(2, brake_shape(0, 1.0))
        self.scanner.tick()
        self.assertEqual(len(self.events()), 1)

    def test_reprocessing_failure_rolls_back(self):
        self.start()
        self.add(1, brake_shape(10, 2.0))
        with mock.patch.object(telemetry, "meta_set", side_effect=RuntimeError("disk")):
            with self.assertRaises(RuntimeError):
                self.scanner.tick()
        self.assertEqual(self.events(), [])
        self.assertEqual(self.watermark(), name_at(0))

    def test_encrypted_clips_are_counted(self):
        path = os.path.join(self.root, telemetry.ENCRYPTED_DIR)
        os.makedirs(path)
        open(os.path.join(path, "x"), "w").close()
        self.start()
        self.assertEqual(telemetry.meta_get(self.conn, "encrypted_recent"), "1")

    def test_prune_ages_by_newest_sample(self):
        self.start()
        self.conn.execute("INSERT INTO samples (t, clip) VALUES (1000, 'ancient')")
        self.conn.commit()
        telemetry.prune(self.conn, 30)
        self.assertEqual(self.conn.execute("SELECT count(*) AS n FROM samples WHERE clip = 'ancient'").fetchone()["n"], 0)
        self.assertGreater(self.conn.execute("SELECT count(*) AS n FROM samples").fetchone()["n"], 0)


class DriveView(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.fstype = "exfat"
        self.fail_mount = False

    def fake_run(self, *command):
        self.calls.append(list(command))
        stdout = ""
        if command[0] == "kpartx":
            stdout = "dashcam-origin1 : 0 1930395648 /dev/mapper/dashcam-origin 2048\n"
        elif command[0] == "blkid":
            stdout = self.fstype + "\n"
        elif command[0] == "mount" and self.fail_mount:
            raise telemetry.subprocess.CalledProcessError(1, command)
        return telemetry.subprocess.CompletedProcess(command, 0, stdout, "")

    def fake_plain(self, command, **_):
        self.calls.append(list(command))
        return telemetry.subprocess.CompletedProcess(command, 0, "", "")

    def enter(self):
        with mock.patch.object(telemetry, "run", self.fake_run), \
                mock.patch.object(telemetry.subprocess, "run", self.fake_plain), \
                mock.patch.object(telemetry.os, "makedirs"):
            with telemetry.drive_view():
                pass

    def named(self, verb):
        return [call for call in self.calls if call[0] == verb]

    def test_device_is_read_only_at_the_partition(self):
        self.enter()
        create = [call for call in self.named("dmsetup") if "create" in call][0]
        self.assertIn("--readonly", create)
        self.assertEqual(create[-1], "0 1930395648 linear /dev/mapper/dashcam-origin 2048")

    def test_exfat_mounts_read_only(self):
        self.enter()
        self.assertIn("ro,noatime,umask=022", self.named("mount")[0])

    def test_ext4_never_replays_its_journal(self):
        self.fstype = "ext4"
        self.enter()
        self.assertIn("ro,noatime,noload", self.named("mount")[0])

    def test_unknown_filesystem_is_refused_and_cleaned_up(self):
        self.fstype = "ntfs"
        with self.assertRaises(RuntimeError):
            self.enter()
        self.assertEqual(self.named("mount"), [])
        self.assertEqual(self.named("dmsetup")[-1], ["dmsetup", "remove", telemetry.VIEW_NAME])

    def test_failed_mount_removes_the_view(self):
        self.fail_mount = True
        with self.assertRaises(telemetry.subprocess.CalledProcessError):
            self.enter()
        self.assertEqual(self.named("dmsetup")[-1], ["dmsetup", "remove", telemetry.VIEW_NAME])

    def test_view_is_removed_after_unmount(self):
        self.enter()
        order = [call[0] for call in self.calls]
        self.assertLess(len(order) - 1 - order[::-1].index("umount"), len(order) - 1 - order[::-1].index("dmsetup"))

    def test_no_partition_table_uses_the_whole_disk(self):
        original = self.fake_run

        def whole(*command):
            if command[0] == "kpartx":
                return telemetry.subprocess.CompletedProcess(command, 0, "", "")
            if command[0] == "blockdev":
                return telemetry.subprocess.CompletedProcess(command, 0, "4096\n", "")
            return original(*command)
        with mock.patch.object(telemetry, "run", whole):
            self.assertEqual(telemetry.origin_extent(), (0, 4096))


class Alerts(ScannerBase):
    def event(self, gps=False):
        self.start()
        self.add(1, brake_shape(10, 2.0))
        self.scanner.tick()
        return telemetry.row_dict(self.events()[0])

    def test_gps_stays_out_by_default(self):
        event = self.event()
        data, kind = telemetry.alert_request(event, CFG)
        self.assertEqual(kind, "application/json")
        self.assertNotIn(b"37.5", data)
        self.assertNotIn("lat", json.loads(data)["event"])

    def test_gps_when_asked(self):
        data, _ = telemetry.alert_request(self.event(), dict(CFG, webhook_gps=True))
        self.assertEqual(json.loads(data)["event"]["lat"], 37.5)

    def test_text_format(self):
        data, kind = telemetry.alert_request(self.event(), dict(CFG, webhook_format="text"))
        self.assertTrue(kind.startswith("text/plain"))
        self.assertTrue(data.decode().startswith("Hard braking: 6.0"))

    def test_sent_alert_is_marked(self):
        self.event()
        sent = []
        telemetry.send_alerts(self.conn, CFG, post=lambda e, c: sent.append(e["id"]))
        self.assertEqual(len(sent), 1)
        self.assertEqual(self.events()[0]["alert_state"], "sent")
        telemetry.send_alerts(self.conn, CFG, post=lambda e, c: sent.append(e["id"]))
        self.assertEqual(len(sent), 1)

    def test_failed_alert_waits_and_retries(self):
        self.event()
        clock = [1000.0]

        def down(_event, _cfg):
            raise OSError("no network")
        telemetry.send_alerts(self.conn, CFG, post=down, now=lambda: clock[0])
        row = self.events()[0]
        self.assertEqual((row["alert_state"], row["alert_attempts"]), ("pending", 1))
        self.assertEqual(row["alert_next_at"], 1060.0)
        sent = []
        telemetry.send_alerts(self.conn, CFG, post=lambda e, c: sent.append(1), now=lambda: 1059.0)
        self.assertEqual(sent, [])
        telemetry.send_alerts(self.conn, CFG, post=lambda e, c: sent.append(1), now=lambda: 1060.0)
        self.assertEqual(self.events()[0]["alert_state"], "sent")

    def test_gives_up_eventually(self):
        self.event()

        def down(_event, _cfg):
            raise OSError("no network")
        self.conn.execute("UPDATE events SET alert_attempts = ?", (telemetry.ALERT_MAX_ATTEMPTS - 1,))
        self.conn.commit()
        telemetry.send_alerts(self.conn, CFG, post=down)
        self.assertEqual(self.events()[0]["alert_state"], "failed")

    def test_failure_log_never_contains_the_url(self):
        self.event()
        secret = "https://example.invalid/secret-hook"

        def down(_event, _cfg):
            raise OSError(secret)
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            telemetry.send_alerts(self.conn, dict(CFG, webhook_url=secret), post=down)
        self.assertNotIn("secret-hook", captured.getvalue())
        self.assertIn("OSError", captured.getvalue())


class ApiServer(ScannerBase):
    def setUp(self):
        super().setUp()
        self.db = os.path.join(self.root, "t.db")
        self.add(0, brake_shape(10, 2.0))
        self.scanner.tick()
        self.server = telemetry.make_server(CFG, self.db)
        self.port = self.server.server_address[1]
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()

        def stop():
            self.server.stop.set()
            self.server.shutdown()
            self.server.server_close()
        self.addCleanup(stop)

    def get(self, path, token=CFG["token"]):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Authorization": "Bearer " + token} if token else {}
        conn.request("GET", path, headers=headers)
        response = conn.getresponse()
        body = response.read()
        conn.close()
        return response.status, json.loads(body)

    def test_health_needs_no_token_and_says_nothing(self):
        self.assertEqual(self.get("/healthz", token=None), (200, {"ok": True}))

    def test_everything_else_needs_the_token(self):
        for path in ("/latest", "/samples", "/events", "/status", "/stream", "/nothing"):
            self.assertEqual(self.get(path, token=None)[0], 401, path)
            self.assertEqual(self.get(path, token="wrong")[0], 401, path)

    def test_latest(self):
        status, body = self.get("/latest")
        self.assertEqual(status, 200)
        self.assertEqual(body["lat"], 37.5)
        self.assertEqual(body["gear"], "drive")

    def test_samples_since_and_limit(self):
        _, every = self.get("/samples?limit=5000")
        self.assertAlmostEqual(len(every), 120, delta=2)
        self.assertEqual(len(self.get("/samples?limit=3")[1]), 3)
        _, later = self.get(f"/samples?since={every[10]['t']}&limit=5000")
        self.assertEqual(later[0]["t"], every[11]["t"])

    def test_limit_has_a_ceiling(self):
        self.conn.executemany("INSERT INTO samples (t) VALUES (?)", [(float(i),) for i in range(telemetry.MAX_ROWS + 50)])
        self.conn.commit()
        self.assertEqual(len(self.get("/samples?limit=999999")[1]), telemetry.MAX_ROWS)

    def test_events_filter_and_hide_alert_state(self):
        _, events = self.get("/events")
        self.assertEqual([event["type"] for event in events], ["hard_brake"])
        self.assertNotIn("alert_attempts", events[0])
        self.assertEqual(self.get("/events?type=hard_corner")[1], [])

    def test_status(self):
        _, status = self.get("/status")
        self.assertEqual(status["last_clip"], name_at(0))
        self.assertEqual(status["events"], 1)

    def test_bad_query_is_400(self):
        self.assertEqual(self.get("/samples?since=yesterday")[0], 400)

    def test_unknown_path_is_404(self):
        self.assertEqual(self.get("/nothing")[0], 404)

    def test_sql_in_a_query_is_only_data(self):
        self.assertEqual(self.get("/events?type=x%27%3BDROP%20TABLE%20events%3B--")[1], [])
        self.assertEqual(self.get("/status")[1]["events"], 1)

    def test_stream_delivers_new_rows(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/stream", headers={"Authorization": "Bearer " + CFG["token"]})
        response = conn.getresponse()
        self.assertEqual(response.status, 200)
        time.sleep(0.4)
        self.conn.execute("INSERT INTO events (type, start_t, end_t, peak, alert_state) VALUES ('hard_accel', 9e9, 9e9, 5, 'none')")
        self.conn.commit()
        seen = [response.readline().decode().strip() for _ in range(2)]
        conn.close()
        self.assertEqual(seen[0], "event: alert")
        self.assertEqual(json.loads(seen[1][len("data: "):])["type"], "hard_accel")

    def test_too_many_streams_are_refused(self):
        for _ in range(telemetry.MAX_STREAMS):
            self.server.streams.acquire()
        self.addCleanup(lambda: [self.server.streams.release() for _ in range(telemetry.MAX_STREAMS)])
        self.assertEqual(self.get("/stream")[0], 503)


class WriteReport(unittest.TestCase):
    def test_streaming(self):
        rows = [(float(i), 10000) for i in range(100)]
        summary = telemetry.summarize_write_log(rows)
        self.assertEqual(summary["p95_gap_s"], 1.0)
        self.assertIn("worth building", summary["verdict"])

    def test_bursts(self):
        rows = [(i * 10.0, 10000) for i in range(50)]
        self.assertIn("some time", telemetry.summarize_write_log(rows)["verdict"])

    def test_long_hold(self):
        rows = [(i * 60.0, 10000) for i in range(50)]
        self.assertIn("gain little", telemetry.summarize_write_log(rows)["verdict"])

    def test_stops_between_drives_do_not_count(self):
        rows = [(float(i), 10000) for i in range(30)] + [(10000.0 + i, 10000) for i in range(30)]
        self.assertEqual(telemetry.summarize_write_log(rows)["max_gap_s"], 1.0)

    def test_too_little_data(self):
        self.assertIsNone(telemetry.summarize_write_log([(1.0, 1)]))


class Config(unittest.TestCase):
    def test_values_and_defaults(self):
        cfg = telemetry.config_from_env({"TELEMETRY_TOKEN": "abc", "TELEMETRY_BRAKE_MPS2": "3.5", "TELEMETRY_WEBHOOK_GPS": "1"})
        self.assertEqual((cfg["token"], cfg["brake_mps2"], cfg["webhook_gps"], cfg["port"]), ("abc", 3.5, True, 8088))

    def test_file_is_not_world_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "c.json")
            with mock.patch.dict(os.environ, {"TELEMETRY_TOKEN": "abcdefghijklmnop"}):
                telemetry.write_config(path, None)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o640)
            self.assertEqual(telemetry.load_config(path)["token"], "abcdefghijklmnop")


if __name__ == "__main__":
    unittest.main(verbosity=0)
