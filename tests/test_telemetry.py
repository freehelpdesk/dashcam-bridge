#!/usr/bin/env python3
"""Tests for scripts/telemetry.py. Synthetic clips, and no Pi or root needed."""
import contextlib
import datetime
import http.client
import importlib.util
import io
import json
import os
import re
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

CFG = telemetry.config_from_env({"TELEMETRY_TOKEN": "test-token-1234567890", "TELEMETRY_WEBHOOK_URL": "https://example.invalid/hook"})
CFG.update(port=0, bind="127.0.0.1")


def modes(cfg=CFG, **changes):
    """A copy of cfg with some alert modes changed."""
    out = json.loads(json.dumps(cfg))
    for kind, mode in changes.items():
        out["alerts"][kind]["mode"] = mode
    return out


def only(*kinds, **settings):
    """A config with just these alerts on."""
    out = modes(**{kind: "off" for kind in telemetry.ALERTS})
    for kind in kinds:
        out["alerts"][kind]["mode"] = "alert"
    out.update(settings)
    return out


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


def proto(speed=0.0, forward=0.0, side=0.0, brake=False, gear=1, lat=None, steering=0.0, autopilot=0,
          blinker_left=False, z=0.0, heading=0.0):
    data = field(1, 0, varint(1)) + field(2, 0, varint(gear))
    if speed:
        data += field(4, 5, struct.pack("<f", speed))
    if steering:
        data += field(6, 5, struct.pack("<f", steering))
    if blinker_left:
        data += field(7, 0, varint(1))
    if brake:
        data += field(9, 0, varint(1))
    if autopilot:
        data += field(10, 0, varint(autopilot))
    if lat is not None:
        data += field(11, 1, struct.pack("<d", lat)) + field(12, 1, struct.pack("<d", -lat))
    if heading:
        data += field(13, 1, struct.pack("<d", heading))
    if z:
        data += field(16, 1, struct.pack("<d", z))
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
        self.flags = 0
        self.boot = "boot-1"
        self.scratch_pct = None
        self.now = 1000.0
        self.views = 0
        self.held = True
        patcher = mock.patch.object(telemetry, "drive_percent", return_value=10)  # Not this machine's disk.
        patcher.start()
        self.addCleanup(patcher.stop)
        self.scanner = telemetry.Scanner(
            self.conn, CFG, view=self.view, lock=self.lock, exists=lambda: True, sectors=lambda: self.writes,
            throttled=lambda: self.flags, boot_id=lambda: self.boot, scratch=lambda: self.scratch_pct,
            clock=lambda: self.now, gadget=lambda: "configured")
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


def custom(fn, duration=60.0):
    """A clip from fn(t), which returns keyword arguments for proto()."""
    payloads = [proto(**fn(i / HZ)) for i in range(int(duration * HZ))]
    with tempfile.NamedTemporaryFile(suffix=".mp4") as handle:
        handle.write(mp4(payloads, duration))
        handle.flush()
        return telemetry.read_clip(handle.name)


def kinds_of(clip, cfg):
    return [event["type"] for event in telemetry.detect_events(clip, cfg)]


class NewDetectors(unittest.TestCase):
    def test_modes_gate_detection(self):
        clip = clip_from(brake_shape(10, 2.0))
        self.assertEqual(kinds_of(clip, modes(hard_brake="off")), [])
        self.assertEqual(kinds_of(clip, modes(hard_brake="log")), ["hard_brake"])

    def test_impact_needs_only_a_few_frames(self):
        clip = custom(lambda t: dict(speed=15.0, forward=-20.0 if 10 <= t < 10.06 else 0.0))
        self.assertEqual(kinds_of(clip, only("impact")), ["impact"])

    def test_single_frame_is_not_an_impact(self):
        clip = custom(lambda t: dict(speed=15.0, forward=-20.0 if 10 <= t < 10.02 else 0.0))
        self.assertEqual(kinds_of(clip, only("impact")), [])

    def test_impact_reports_the_stop(self):
        clip = custom(lambda t: dict(speed=15.0 if t < 10.1 else 0.0, forward=-20.0 if 10 <= t < 10.06 else 0.0))
        self.assertTrue(telemetry.detect_events(clip, only("impact"))[0]["detail"]["stopped"])

    def swerve(self, t):
        if 10 <= t < 10.5:
            return dict(speed=25.0, steering=20.0, side=4.0)
        if 10.5 <= t < 11:
            return dict(speed=25.0, steering=-20.0, side=-4.0)
        return dict(speed=25.0)

    def test_swerve(self):
        self.assertEqual(kinds_of(custom(self.swerve), only("swerve")), ["swerve"])

    def test_one_way_turn_is_not_a_swerve(self):
        clip = custom(lambda t: dict(speed=25.0, steering=45.0 if 10 <= t < 15 else 0.0, side=4.0 if 10 <= t < 15 else 0.0))
        self.assertEqual(kinds_of(clip, only("swerve")), [])

    def test_slow_swerve_is_ignored(self):
        clip = custom(lambda t: dict(self.swerve(t), speed=5.0))
        self.assertEqual(kinds_of(clip, only("swerve")), [])

    def test_pothole(self):
        clip = custom(lambda t: dict(speed=15.0, z=6.0 if 10 <= t < 10.05 else 0.0))
        self.assertEqual(kinds_of(clip, only("pothole")), ["pothole"])

    def takeover(self, **during):
        def shape(t):
            base = dict(speed=20.0, autopilot=1 if t < 20 else 0)
            if 19.5 <= t < 20.5:
                base.update(during)
            return base
        return custom(shape)

    def test_takeover_by_braking(self):
        events = telemetry.detect_events(self.takeover(forward=-3.0), only("autopilot_takeover"))
        self.assertEqual(events[0]["detail"]["cause"], "braking")
        self.assertEqual(events[0]["detail"]["mode"], "self_driving")

    def test_takeover_by_steering(self):
        def shape(t):
            return dict(speed=20.0, autopilot=1 if t < 20 else 0, steering=(t - 19.5) * 300 if 19.5 <= t < 20 else 0.0)
        self.assertEqual(telemetry.detect_events(custom(shape), only("autopilot_takeover"))[0]["detail"]["cause"], "steering")

    def test_calm_disengagement_is_quiet(self):
        self.assertEqual(kinds_of(self.takeover(), only("autopilot_takeover")), [])

    def test_engaging_is_quiet(self):
        clip = custom(lambda t: dict(speed=20.0, autopilot=0 if t < 20 else 1, forward=-3.0 if 19 < t < 21 else 0.0))
        self.assertEqual(kinds_of(clip, only("autopilot_takeover")), [])

    def lane(self, **extra):
        def shape(t):
            heading = 100.0
            if 10 <= t < 13:
                heading += 3.0  # Angled across the lane, then straight again.
            return dict(speed=25.0, heading=heading, **extra)
        return custom(shape)

    def test_lane_change_without_blinker(self):
        self.assertEqual(kinds_of(self.lane(), only("lane_no_blinker")), ["lane_no_blinker"])

    def test_lane_change_with_blinker_is_fine(self):
        self.assertEqual(kinds_of(self.lane(blinker_left=True), only("lane_no_blinker")), [])

    def test_autopilot_lane_change_is_fine(self):
        self.assertEqual(kinds_of(self.lane(autopilot=1), only("lane_no_blinker")), [])

    def test_straight_road_has_no_lane_change(self):
        self.assertEqual(kinds_of(custom(lambda t: dict(speed=25.0, heading=100.0)), only("lane_no_blinker")), [])

    def test_speeding_fixed_limit(self):
        clip = custom(lambda t: dict(speed=40.0 if 10 <= t < 20 else 30.0))
        events = telemetry.detect_events(clip, only("speeding", speeding_mph=80.0))
        self.assertEqual(events[0]["detail"]["limit_mph"], 80.0)
        self.assertAlmostEqual(events[0]["detail"]["top_mph"], 89.5, delta=0.1)

    def test_brief_speeding_is_ignored(self):
        clip = custom(lambda t: dict(speed=40.0 if 10 <= t < 12 else 30.0))
        self.assertEqual(kinds_of(clip, only("speeding", speeding_mph=80.0)), [])

    def test_smallest_speeding_zone_wins(self):
        zones = [{"name": "town", "lat": 37.5, "lon": -37.5, "radius": 5000.0, "mph": 40.0},
                 {"name": "school", "lat": 37.5, "lon": -37.5, "radius": 100.0, "mph": 20.0}]
        clip = custom(lambda t: dict(speed=15.0, lat=37.5))
        events = telemetry.detect_events(clip, only("speeding", speeding_mph=0.0, speeding_zones=zones))
        self.assertEqual(events[0]["detail"]["limit_mph"], 20.0)

    def test_zero_limit_without_zones_is_off(self):
        clip = custom(lambda t: dict(speed=60.0, lat=37.5))
        self.assertEqual(kinds_of(clip, only("speeding", speeding_mph=0.0)), [])


class Tracking(ScannerBase):
    def setUp(self):
        super().setUp()
        self.add_fn(0, lambda t: dict(speed=0.0, gear=0))
        self.scanner.tick()

    def add_fn(self, minute, fn):
        payloads = [proto(**fn(i / HZ)) for i in range(60 * HZ)]
        with open(os.path.join(self.clips, name_at(minute)), "wb") as handle:
            handle.write(mp4(payloads, 60.0))
        self.writes += 1

    def run_clips(self, fns, cfg=None):
        self.scanner.cfg = cfg or CFG
        for minute, fn in fns:
            self.add_fn(minute, fn)
            self.scanner.tick()

    def of(self, kind):
        return [telemetry.event_public(row) for row in self.events() if row["type"] == kind]

    def test_trip_summary_when_parked(self):
        moving = lambda t: dict(speed=20.0, autopilot=1 if t < 30 else 0, gear=1)
        parks = lambda t: dict(speed=20.0, gear=1) if t < 30 else dict(speed=0.0, gear=0)
        self.run_clips([(1, moving), (2, moving), (3, parks)])
        summary = self.of("trip_summary")[-1]["detail"]
        self.assertGreater(summary["miles"], 1.8)
        self.assertEqual(summary["top_mph"], 44.7)
        self.assertGreater(summary["autopilot_pct"], 20)
        self.assertEqual(len(self.of("trip_summary")), 1)

    def test_trip_counts_events(self):
        park = lambda t: dict(speed=0.0, gear=0)
        self.run_clips([(1, lambda t: dict(speed=25.0, gear=1, forward=-6.0 if 10 <= t < 12 else 0.0) if t < 10 or t >= 12 else dict(speed=25.0 - 6 * (t - 10), forward=-6.0, gear=1)), (2, park)])
        self.assertEqual(self.of("trip_summary")[-1]["detail"]["events"], {"hard_brake": 1})

    def test_no_sei_ends_a_trip(self):
        self.run_clips([(1, lambda t: dict(speed=20.0, gear=1))])
        self.add(2, duration=0.0)
        self.scanner.tick()
        self.assertEqual(len(self.of("trip_summary")), 1)

    def test_tiny_trip_is_not_reported(self):
        self.run_clips([(1, lambda t: dict(speed=2.0 if t < 5 else 0.0, gear=1 if t < 5 else 0))])
        self.assertEqual(self.of("trip_summary"), [])

    def test_geofence_arrival_and_departure(self):
        cfg = only("geofence", geofence_zones=[{"name": "home", "lat": 37.5, "lon": -37.5, "radius": 100.0}])
        away = lambda t: dict(speed=10.0, lat=37.6)
        here = lambda t: dict(speed=10.0, lat=37.5)
        self.run_clips([(1, away), (2, here), (3, away)], cfg)
        self.assertEqual([e["detail"]["action"] for e in self.of("geofence")], ["arrived", "left"])

    def test_geofence_first_sighting_is_silent(self):
        cfg = only("geofence", geofence_zones=[{"name": "home", "lat": 37.5, "lon": -37.5, "radius": 100.0}])
        self.run_clips([(1, lambda t: dict(speed=10.0, lat=37.5))], cfg)
        self.assertEqual(self.of("geofence"), [])

    def test_geofence_edge_does_not_flap(self):
        cfg = only("geofence", geofence_zones=[{"name": "home", "lat": 37.5, "lon": -37.5, "radius": 100.0}])
        inside = lambda t: dict(speed=10.0, lat=37.5, )
        edge = lambda t: dict(speed=10.0, lat=37.5 + 85 / 111195)  # About 110 m away, inside the exit margin.
        self.run_clips([(1, inside), (2, edge), (3, inside)], cfg)
        self.assertEqual(self.of("geofence"), [])

    def test_quiet_hours_wrap_midnight(self):
        moment = datetime.datetime(2026, 11, 7, 23, 30).timestamp()
        noon = datetime.datetime(2026, 11, 7, 12, 0).timestamp()
        early = datetime.datetime(2026, 11, 8, 4, 59).timestamp()
        self.assertTrue(telemetry.in_quiet_hours(moment, "23-5"))
        self.assertTrue(telemetry.in_quiet_hours(early, "23-5"))
        self.assertFalse(telemetry.in_quiet_hours(noon, "23-5"))
        self.assertFalse(telemetry.in_quiet_hours(noon, ""))

    def test_unexpected_quiet_hours_once_per_trip(self):
        moving = lambda t: dict(speed=10.0, gear=1)
        self.run_clips([(1, moving), (2, moving)], only("unexpected_use", unexpected_hours="0-0"))
        self.assertEqual(self.of("unexpected_use"), [])
        self.run_clips([(3, lambda t: dict(speed=0.0, gear=0))], only("unexpected_use", unexpected_hours="18-19"))
        self.run_clips([(4, moving), (5, moving)], only("unexpected_use", unexpected_hours="18-19"))
        self.assertEqual([e["detail"]["reason"] for e in self.of("unexpected_use")], ["quiet hours"])

    def test_outside_area_alerts_once(self):
        cfg = only("unexpected_use", unexpected_area={"lat": 37.5, "lon": -37.5, "radius": 1000.0})
        outside = lambda t: dict(speed=10.0, gear=1, lat=38.5)
        self.run_clips([(1, outside), (2, outside)], cfg)
        self.assertEqual([e["detail"]["reason"] for e in self.of("unexpected_use")], ["outside the allowed area"])

    def test_blinker_left_on_spans_clips(self):
        cfg = only("blinker_left_on", blinker_secs=30.0)
        late = lambda t: dict(speed=30.0, blinker_left=t >= 45)
        early = lambda t: dict(speed=30.0, blinker_left=True)
        self.run_clips([(1, late), (2, early)], cfg)
        found = self.of("blinker_left_on")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["detail"]["side"], "left")

    def test_separate_blinks_do_not_add_up(self):
        def shape(t):
            return dict(speed=30.0, blinker_left=t < 20 or t >= 30)
        self.run_clips([(1, shape)], only("blinker_left_on", blinker_secs=35.0))
        self.assertEqual(self.of("blinker_left_on"), [])

    def test_blinker_at_low_speed_is_fine(self):
        self.run_clips([(1, lambda t: dict(speed=5.0, blinker_left=True))], only("blinker_left_on", blinker_secs=30.0))
        self.assertEqual(self.of("blinker_left_on"), [])

    def test_lost_sei_after_many_clips(self):
        self.scanner.cfg = only("telemetry_lost", sei_lost_clips=3)
        for minute in range(1, 6):
            self.add(minute, duration=0.0)
            self.scanner.tick()
        self.assertEqual(len(self.of("telemetry_lost")), 1)

    def test_sei_return_rearms_the_alert(self):
        self.scanner.cfg = only("telemetry_lost", sei_lost_clips=2)
        for minute in (1, 2):
            self.add(minute, duration=0.0)
            self.scanner.tick()
        self.add(3)
        self.scanner.tick()
        for minute in (4, 5):
            self.add(minute, duration=0.0)
            self.scanner.tick()
        self.assertEqual(len(self.of("telemetry_lost")), 2)

    def test_state_survives_a_restart(self):
        self.run_clips([(1, lambda t: dict(speed=20.0, gear=1))])
        self.scanner = telemetry.Scanner(self.conn, CFG, view=self.view, lock=self.lock, exists=lambda: True, sectors=lambda: self.writes)
        self.run_clips([(2, lambda t: dict(speed=0.0, gear=0))])
        self.assertGreater(self.of("trip_summary")[-1]["detail"]["miles"], 0.5)


class Folders(ScannerBase):
    def setUp(self):
        super().setUp()
        self.base = os.path.join(self.root, "TeslaCam")
        for folder in ("SentryClips", "SavedClips"):
            os.makedirs(os.path.join(self.base, folder))
        self.start()
        self.scan()

    def scan(self):
        self.writes += 1
        self.scanner.tick()

    def folder(self, where, name, info=None):
        path = os.path.join(self.base, where, name)
        os.makedirs(path)
        if info is not None:
            with open(os.path.join(path, "event.json"), "w") as handle:
                json.dump(info, handle)

    def test_existing_folders_are_not_news(self):
        self.assertEqual(self.events(), [])

    def test_new_sentry_folder_alerts_with_reason(self):
        self.folder("SentryClips", "2026-11-07_17-24-45", {"reason": "sentry_aware_object_detection", "est_lat": "37.5", "est_lon": "-122", "city": "Town", "street": "Main"})
        self.scan()
        event = telemetry.row_dict(self.events()[0])
        self.assertEqual((event["type"], event["alert_state"]), ("sentry_event", "pending"))
        self.assertIn("sentry aware object detection", telemetry.event_message(event))
        self.assertEqual(self.events()[0]["lat"], 37.5)

    def test_location_stays_out_of_the_webhook(self):
        self.folder("SavedClips", "2026-11-07_17-24-45", {"reason": "vehicle_auto_emergency_braking", "city": "Secretville", "street": "Hidden Rd", "est_lat": "37.5", "est_lon": "-122"})
        self.scan()
        event = telemetry.row_dict(self.events()[0])
        data, _ = telemetry.alert_request(event, CFG)
        self.assertNotIn(b"Secretville", data)
        self.assertNotIn(b"Hidden Rd", data)
        self.assertNotIn(b"37.5", data)
        data, _ = telemetry.alert_request(event, dict(CFG, webhook_gps=True))
        self.assertIn(b"Secretville", data)

    def test_waits_for_event_json(self):
        self.folder("SentryClips", "2026-11-07_17-24-45")
        self.scan()
        self.assertEqual(self.events(), [])
        with open(os.path.join(self.base, "SentryClips", "2026-11-07_17-24-45", "event.json"), "w") as handle:
            json.dump({"reason": "late"}, handle)
        self.scanner.tick()  # Retries with no new writes.
        self.assertEqual(json.loads(self.events()[0]["detail"])["reason"], "late")

    def test_missing_event_json_is_reported_eventually(self):
        self.folder("SentryClips", "2026-11-07_17-24-45")
        for _ in range(telemetry.FOLDER_RETRIES):
            self.scan()
        self.assertEqual(json.loads(self.events()[0]["detail"])["reason"], "unknown")
        self.assertEqual(len(self.events()), 1)

    def test_junk_event_json_is_survived(self):
        self.folder("SentryClips", "2026-11-07_17-24-45", ["not", "a", "dict"])
        self.scan()
        self.assertEqual(len(self.events()), 1)

    def test_off_means_no_event_and_no_backlog(self):
        self.scanner.cfg = modes(sentry_event="off")
        self.folder("SentryClips", "2026-11-07_17-24-45", {"reason": "x"})
        self.scan()
        self.scanner.cfg = CFG
        self.scan()
        self.assertEqual(self.events(), [])

    def test_macos_junk_folders_are_ignored(self):
        self.folder("SentryClips", ".Spotlight", {"reason": "x"})
        self.scan()
        self.assertEqual(self.events(), [])


class Health(ScannerBase):
    def setUp(self):
        super().setUp()
        self.scanner.cfg = only("power_trouble", "recording_stopped", "storage_full", "telemetry_lost")

    def kinds(self):
        return [row["type"] for row in self.events()]

    def test_power_flag_alerts_once(self):
        self.flags = 0x10000
        self.scanner.health()
        self.scanner.health()
        self.assertEqual(self.kinds(), ["power_trouble"])
        self.assertEqual(json.loads(self.events()[0]["detail"])["flags"], ["undervoltage"])

    def test_a_second_flag_alerts_too(self):
        self.flags = 0x10000
        self.scanner.health()
        self.flags = 0x50000
        self.scanner.health()
        self.assertEqual(json.loads(self.events()[1]["detail"])["flags"], ["throttled"])

    def test_power_flags_rearm_after_a_reboot(self):
        self.flags = 0x10000
        self.scanner.health()
        self.boot = "boot-2"
        self.scanner.health()
        self.assertEqual(len(self.kinds()), 2)

    def test_no_vcgencmd_is_quiet(self):
        self.flags = None
        self.scanner.health()
        self.assertEqual(self.kinds(), [])

    def moving(self):
        self.add(0)
        self.scanner.tick()

    def test_recording_stopped_mid_drive(self):
        self.moving()
        self.now += 299
        self.scanner.health()
        self.assertEqual(self.kinds(), [])
        self.now += 2
        self.scanner.health()
        self.scanner.health()
        self.assertEqual(self.kinds(), ["recording_stopped"])

    def test_parked_car_is_not_a_stopped_recording(self):
        self.now += 10000
        self.scanner.health()
        self.assertEqual(self.kinds(), [])

    def test_new_clip_rearms_recording(self):
        self.moving()
        self.now += 400
        self.scanner.health()
        self.add(1)
        self.scanner.tick()
        self.now += 400
        self.scanner.health()
        self.assertEqual(self.kinds(), ["recording_stopped", "recording_stopped"])

    def test_scratch_alerts_once_and_rearms(self):
        self.scratch_pct = 85
        self.scanner.health()
        self.scanner.health()
        self.assertEqual(len(self.kinds()), 1)
        self.scratch_pct = 79
        self.scanner.health()
        self.scratch_pct = 85
        self.scanner.health()
        self.assertEqual(len(self.kinds()), 1)  # 79 is inside the margin.
        self.scratch_pct = 70
        self.scanner.health()
        self.scratch_pct = 85
        self.scanner.health()
        self.assertEqual(len(self.kinds()), 2)

    def test_drive_full(self):
        self.start()
        with mock.patch.object(telemetry, "drive_percent", return_value=95):
            self.writes += 1
            self.scanner.tick()
        self.assertEqual(json.loads(self.events()[0]["detail"])["which"], "drive")

    def test_encrypted_clips_appearing(self):
        path = os.path.join(self.root, telemetry.ENCRYPTED_DIR)
        os.makedirs(path)
        self.start()
        open(os.path.join(path, "x"), "w").close()
        self.writes += 1
        self.scanner.tick()
        self.assertEqual(self.kinds(), ["telemetry_lost"])


class Routing(ScannerBase):
    def event_of(self, kind, cfg):
        with self.conn:
            telemetry.record_event(self.conn, cfg, telemetry._state_event(kind, 100.0, reason="x"), "", True)
        return telemetry.row_dict(self.events()[-1])

    def own(self, **hooks):
        cfg = json.loads(json.dumps(CFG))
        for kind, url in hooks.items():
            cfg["alerts"][kind]["webhook"] = url
        return cfg

    def test_own_webhook_wins(self):
        self.assertEqual(telemetry.alert_target("sentry_event", self.own(sentry_event="https://own"))[0], "https://own")

    def test_default_webhook_otherwise(self):
        self.assertEqual(telemetry.alert_target("saved_clip", CFG)[0], CFG["webhook_url"])

    def test_own_format_wins(self):
        cfg = self.own()
        cfg["alerts"]["sentry_event"]["format"] = "text"
        event = self.event_of("sentry_event", cfg)
        self.assertTrue(telemetry.alert_request(event, cfg)[1].startswith("text/plain"))
        self.assertEqual(telemetry.alert_target("saved_clip", cfg)[1], "json")

    def test_log_mode_is_never_sent(self):
        self.assertEqual(self.event_of("sentry_event", modes(sentry_event="log"))["alert_state"], "none")

    def test_own_webhook_works_with_no_default(self):
        cfg = self.own(sentry_event="https://own")
        cfg["webhook_url"] = ""
        self.assertEqual(self.event_of("sentry_event", cfg)["alert_state"], "pending")
        cfg2 = dict(cfg)
        self.assertEqual(self.event_of("saved_clip", cfg2)["alert_state"], "none")

    def test_one_dead_webhook_does_not_block_another(self):
        cfg = self.own(sentry_event="https://dead", saved_clip="https://alive")
        self.event_of("sentry_event", cfg)
        self.event_of("saved_clip", cfg)
        delivered = []

        def post(event, config):
            url = telemetry.alert_target(event["type"], config)[0]
            if url == "https://dead":
                raise OSError("down")
            delivered.append(url)
        telemetry.send_alerts(self.conn, cfg, post=post)
        self.assertEqual(delivered, ["https://alive"])

    def test_dead_webhook_is_tried_once_per_pass(self):
        cfg = self.own(sentry_event="https://dead")
        for _ in range(3):
            self.event_of("sentry_event", cfg)
        tries = []

        def post(event, config):
            tries.append(event["id"])
            raise OSError("down")
        telemetry.send_alerts(self.conn, cfg, post=post)
        self.assertEqual(len(tries), 1)

    def test_every_alert_has_a_message(self):
        details = {
            "autopilot_takeover": dict(mode="self_driving", cause="braking"), "lane_no_blinker": dict(offset_m=3.0),
            "blinker_left_on": dict(side="left", seconds=30), "speeding": dict(top_mph=90.0, limit_mph=85.0),
            "geofence": dict(zone="home", action="arrived"), "unexpected_use": dict(reason="quiet hours"),
            "trip_summary": dict(miles=1.0, minutes=2.0, top_mph=30.0, autopilot_pct=5, events={}),
            "sentry_event": dict(reason="x"), "saved_clip": dict(reason="x"),
            "recording_stopped": dict(minutes=5.0, usb="configured"), "power_trouble": dict(flags=["undervoltage"]),
            "storage_full": dict(which="drive", percent=91), "telemetry_lost": dict(reason="x"), "impact": dict(stopped=True),
        }
        for kind in telemetry.ALERTS:
            event = {"type": kind, "start_t": 100.0, "peak": 5.0, "speed_start": 10.0, "detail": json.dumps(details.get(kind, {}))}
            self.assertTrue(telemetry.event_message(event), kind)


class AlertConfig(unittest.TestCase):
    def test_modes_and_webhooks_from_env(self):
        cfg = telemetry.config_from_env({
            "TELEMETRY_TOKEN": "x", "TELEMETRY_ALERT_POTHOLE": "log", "TELEMETRY_ALERT_POTHOLE_WEBHOOK": "https://p",
            "TELEMETRY_ALERT_POTHOLE_WEBHOOK_FORMAT": "text"})
        self.assertEqual(cfg["alerts"]["pothole"], {"mode": "log", "webhook": "https://p", "format": "text"})

    def test_blank_values_use_defaults(self):
        cfg = telemetry.config_from_env({"TELEMETRY_TOKEN": "x", "TELEMETRY_ALERT_HARD_BRAKE": "", "TELEMETRY_IMPACT_MPS2": ""})
        self.assertEqual((cfg["alerts"]["hard_brake"]["mode"], cfg["impact_mps2"]), ("alert", 12.0))

    def test_zones_parse(self):
        zones = telemetry.parse_zones("home:37.5,-122.1:150;work:37.4,-122.0:200;")
        self.assertEqual([z["name"] for z in zones], ["home", "work"])
        self.assertEqual(zones[0]["lon"], -122.1)
        self.assertEqual(telemetry.parse_zones("s:1,2:300:25", with_limit=True)[0]["mph"], 25.0)

    def test_bad_zone_is_refused(self):
        with self.assertRaises(ValueError):
            telemetry.parse_zones("home:37.5:150")

    def test_shell_and_python_list_the_same_alerts(self):
        with open(os.path.join(SCRIPTS, "common.sh")) as handle:
            listed = re.search(r"^TELEMETRY_ALERT_NAMES=\((.*)\)$", handle.read(), re.M).group(1).split()
        self.assertEqual(listed, list(telemetry.ALERTS))

    def test_template_has_a_mode_and_webhook_for_each(self):
        with open(os.path.join(SCRIPTS, "..", "config", "dashcam-bridge.env")) as handle:
            template = handle.read()
        for kind, (mode, _) in telemetry.ALERTS.items():
            key = "TELEMETRY_ALERT_" + kind.upper()
            self.assertIn(f"\n{key}={mode}\n{key}_WEBHOOK=\n", template, kind)


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
        self.assertRegex(data.decode(), r"^Hard braking at \d\d:\d\d:\d\d: 6\.0")

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
        self.assertEqual(status["alerts"]["hard_brake"], {"mode": "alert", "webhook": True})
        self.assertEqual(status["alerts"]["swerve"]["mode"], "off")

    def test_status_never_shows_a_webhook_url(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/status", headers={"Authorization": "Bearer " + CFG["token"]})
        self.assertNotIn(b"example.invalid", conn.getresponse().read())
        conn.close()

    def test_event_detail_is_an_object(self):
        self.assertEqual(self.get("/events")[1][0]["detail"], {})

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
