#!/usr/bin/python3 -I
"""Tests for the presence daemon's filter and record decoding. Run: tests/run"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "system", "presenced")
loader = importlib.machinery.SourceFileLoader("presenced", path)
spec = importlib.util.spec_from_loader("presenced", loader)
presenced = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(presenced)


def run(filter_, events, until):
    """Feed (time, present, attentive, distance) events, ticking every 0.1 s."""
    events = sorted(events)
    states = {}
    step = 0
    while step / 10 <= until:
        now = step / 10
        while events and events[0][0] <= now + 1e-9:
            _, present, attentive, distance = events.pop(0)
            filter_.feed(present, attentive, distance, now, 1000 + now)
        filter_.tick(now, 1000 + now)
        states[round(now, 1)] = (filter_.present, filter_.attentive)
        step += 1
    return states


class FilterTest(unittest.TestCase):
    def make(self):
        return presenced.Filter(arrive=1.0, leave=5.0, hold=5.0)

    def test_unknown_until_the_sensor_has_decided(self):
        f = self.make()
        self.assertIsNone(f.present)
        states = run(f, [(0, False, False, 0)], 6)
        self.assertIsNone(states[4.9][0])
        self.assertIs(states[5.0][0], False)

    def test_arrival_needs_a_second_of_presence(self):
        f = self.make()
        states = run(f, [(0, True, True, 400)], 2)
        self.assertIsNone(states[0.9][0])
        self.assertEqual(states[1.0], (True, True))
        self.assertEqual(f.distance_mm, 400)

    def test_camera_dropout_is_ignored(self):
        # Seen on the PX13: opening the camera blanks the sensor for ~3 s.
        f = self.make()
        states = run(f, [(0, True, True, 400), (12.1, False, False, 0), (15.3, True, True, 424)], 20)
        self.assertTrue(all(state == (True, True) for t, state in states.items() if t >= 1.0))

    def test_leaving_takes_five_seconds_and_clears_attention(self):
        f = self.make()
        states = run(f, [(0, True, True, 400), (10, False, False, 0)], 16)
        self.assertEqual(states[14.9], (True, True))
        self.assertEqual(states[15.0], (False, False))
        # Counted from when the seat emptied, not from when that was believed.
        self.assertEqual(f.since, 1010.0)
        self.assertIsNone(f.snapshot(0)["distance_mm"])

    def test_no_distance_is_published_for_an_empty_seat(self):
        f = self.make()
        run(f, [(0, False, False, 0), (6, True, False, 857), (6.6, False, False, 0)], 7)
        self.assertIsNone(f.snapshot(0)["distance_mm"])

    def test_a_brief_phantom_does_not_count_as_arriving(self):
        f = self.make()
        states = run(f, [(0, False, False, 0), (6, True, False, 857), (6.6, False, False, 0)], 12)
        self.assertTrue(all(state[0] is False for t, state in states.items() if t >= 5.0))

    def test_attention_is_held_then_dropped(self):
        f = self.make()
        states = run(f, [(0, True, True, 400), (3, True, False, 400)], 9)
        self.assertEqual(states[7.9], (True, True))
        self.assertEqual(states[8.0], (True, False))

    def test_attention_returns_at_once(self):
        f = self.make()
        states = run(f, [(0, True, False, 800), (2, True, True, 500)], 3)
        self.assertEqual(states[1.9], (True, False))
        self.assertEqual(states[2.0], (True, True))

    def test_camera_privacy_hides_what_the_blinded_sensor_says(self):
        f = self.make()
        run(f, [(0, True, True, 400), (3, False, False, 0)], 12)
        self.assertIs(f.present, False)
        blind = f.snapshot(0, camera_privacy=True)
        self.assertIsNone(blind["present"])
        self.assertIsNone(blind["since"])
        self.assertIs(blind["attentive"], False)
        self.assertIs(blind["camera_privacy"], True)
        self.assertIs(f.snapshot(0, camera_privacy=False)["present"], False)
        self.assertIsNone(f.snapshot(0)["camera_privacy"])

    def test_deadline_tracks_the_next_change(self):
        f = self.make()
        f.feed(True, True, 400, 0.0, 1000.0)
        self.assertAlmostEqual(f.deadline(0.25), 0.75)
        f.tick(1.0, 1001.0)
        self.assertIsNone(f.deadline(1.0))
        f.feed(False, False, 0, 2.0, 1002.0)
        self.assertAlmostEqual(f.deadline(3.0), 4.0)


class FailureTest(unittest.TestCase):
    def test_unavailable_state_claims_nothing(self):
        state = presenced.unavailable("error")
        self.assertEqual(state["sensor"], "error")
        self.assertIsNone(state["present"])
        self.assertIs(state["attentive"], False)
        self.assertIsNone(state["camera_privacy"])

    def test_end_of_file_from_the_device_is_an_error(self):
        read_end, write_end = os.pipe()
        os.close(write_end)
        sensor = presenced.Sensor("/nonexistent/iio:device9")
        sensor.fd, sensor.record_size = read_end, 12
        try:
            with self.assertRaises(OSError):
                sensor.read()
        finally:
            os.close(read_end)


class DecodeTest(unittest.TestCase):
    def test_px13_record_layout(self):
        channels = [
            presenced.Channel("in_proximity0", 0, "le:s8/32>>0"),
            presenced.Channel("in_proximity1", 1, "le:s16/32>>0"),
            presenced.Channel("in_attention", 2, "le:s8/32>>0"),
        ]
        self.assertEqual(presenced.layout(channels), 12)
        record = (1).to_bytes(4, "little") + (412).to_bytes(4, "little") + (100).to_bytes(4, "little")
        self.assertEqual([c.decode(record) for c in channels], [1, 412, 100])

    def test_mixed_sizes_are_aligned(self):
        channels = [presenced.Channel("a", 0, "le:u8/8>>0"), presenced.Channel("b", 1, "be:s16/16>>0")]
        self.assertEqual(presenced.layout(channels), 4)
        self.assertEqual(channels[1].offset, 2)
        self.assertEqual(channels[1].decode(bytes([7, 0, 0xFF, 0xFE])), -2)

    def test_unknown_scan_type_is_refused(self):
        with self.assertRaises(ValueError):
            presenced.Channel("x", 0, "weird")


if __name__ == "__main__":
    unittest.main()
