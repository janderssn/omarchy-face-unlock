#!/usr/bin/python3 -I
"""Tests for the presence daemon's filter and record decoding. Run: tests/run"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
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


class StallTest(unittest.TestCase):
    def test_silence_with_nobody_known_there_is_due_after_the_wait(self):
        stall = presenced.Stall(0.0, first=20.0, longest=100.0)
        self.assertFalse(stall.due(19.9, None))
        self.assertTrue(stall.due(20.0, None))
        self.assertTrue(stall.due(20.0, False))

    def test_someone_sitting_still_is_left_alone(self):
        stall = presenced.Stall(0.0, first=20.0, longest=100.0)
        self.assertFalse(stall.due(500.0, True))

    def test_cycles_back_off_up_to_the_longest_wait(self):
        stall = presenced.Stall(0.0, first=20.0, longest=100.0)
        waits, now = [], 0.0
        for _ in range(5):
            now += stall.wait
            self.assertTrue(stall.due(now, False))
            stall.cycled(now)
            waits.append(stall.wait)
        self.assertEqual(waits, [40.0, 80.0, 100.0, 100.0, 100.0])
        self.assertEqual(stall.cycles, 5)

    def test_a_report_ends_the_silence(self):
        stall = presenced.Stall(0.0, first=20.0, longest=100.0)
        self.assertFalse(stall.heard(5.0))       # nothing to recover from
        self.assertFalse(stall.due(24.9, False))
        stall.cycled(25.0)
        self.assertTrue(stall.heard(26.0))       # the cycle brought it back
        self.assertEqual((stall.wait, stall.cycles), (20.0, 0))
        self.assertFalse(stall.due(45.9, False))
        self.assertTrue(stall.due(46.0, False))


class PowerCycleTest(unittest.TestCase):
    """A stand-in sysfs tree: <tmp>/hid-sensor/{power/runtime_status, iio:device0/...}."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.status = os.path.join(self.tmp.name, "hid-sensor", "power", "runtime_status")
        device = os.path.join(self.tmp.name, "hid-sensor", "iio:device0")
        os.makedirs(os.path.dirname(self.status))
        os.makedirs(device)
        self.sensor = presenced.Sensor(device)
        self.calls = []
        self.sensor.close = lambda: self.calls.append("close")
        self.sensor.open = lambda: self.calls.append("open")

    def set_status(self, value):
        with open(self.status, "w", encoding="ascii") as handle:
            handle.write(value + "\n")

    def test_reopens_once_the_sensor_is_powered_down(self):
        self.set_status("suspended")
        self.assertTrue(self.sensor.power_cycle(timeout=1.0, pause=0.01))
        self.assertEqual(self.calls, ["close", "open"])

    def test_reopens_anyway_when_it_never_powers_down(self):
        self.set_status("active")
        self.assertFalse(self.sensor.power_cycle(timeout=0.05, pause=0.01))
        self.assertEqual(self.calls, ["close", "open"])

    def test_does_not_wait_without_runtime_power_management(self):
        self.set_status("unsupported")
        self.assertFalse(self.sensor.power_cycle(timeout=5.0, pause=0.01))
        os.unlink(self.status)
        self.assertFalse(self.sensor.power_cycle(timeout=5.0, pause=0.01))
        self.assertEqual(self.calls, ["close", "open"] * 2)


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


# The PX13's sensor (ASUS FHD webcam 13D3:52B9): its HID report descriptor,
# and feature report 1 as read on 2026-11-17 with the settings lost and on
# 2026-11-15 with the sensor working (its unique ID replaced by zeros).
PX13_DESCRIPTOR = bytes.fromhex(
    "05200901a101850105200911a10005200a09031500250275089501a1020a30080a31080a3208b100c00a1f03150025037508"
    "9501a1020ac0090ac1090ac2090ac309b100c00a16031500250575089501a1020a40080a41080a42080a43080a44080a4508"
    "b100c00a19031500250575089501a1020a50080a51080a52080a53080a54080a5508b100c00a01021500250675089501a102"
    "0a00080a01080a02080a03080a04080a05080a0608b100c00a0e03150027ffffffff752095015500b1020a0403150027ffff"
    "ffff752095015500b1020ab124150026feff75109501550db1020ab134150026feff75109501550db1020ab214150026feff"
    "75109501550db1020ab174150026feff75109501550db1020abe2415a6255a750895015500b1020abe3415a6255a75089501"
    "5500b1020abe14150025b4750895015500b1020abf2415a6255a750895015500b1020abf3415a6255a750895015500b1020a"
    "bf14150025b4750895015500b1020ac0141500266801751095015500b1020ac1141500266801751095015500b1020ac21415"
    "0025b4750895015500b1020a0103150026ff7f751095105500b1020a0203150026ff7f751095205500b102850205200a0102"
    "1500250675089501a1020a00080a01080a02080a03080a04080a05080a06088100c00a02021500250575089501a1020a1008"
    "0a11080a12080a13080a14080a15088100c00ab1041500250175089501550081020abd041500250175089501550081020ab2"
    "04150026feff75109501550d8102050a0901a10205200ab204150026feff75109501550d81420abd04150025017508950155"
    "0081420abe0415a6255a75089501550081420abf0415a6255a75089501550081420ac0041600002668017510950155008142"
    "0ac104164cff26b40075109501550081420ac20415a6255a75089501550081420ac304150026feff7510950155008142c005"
    "0a0902a10205200ab204150026feff75109501550d81420abd041500250175089501550081420abe0415a6255a7508950155"
    "0081420abf0415a6255a75089501550081420ac00416000026680175109501550081420ac104164cff26b400751095015500"
    "81420ac20415a6255a75089501550081420ac304150026feff7510950155008142c0050a0903a10205200ab204150026feff"
    "75109501550d81420abd041500250175089501550081420abe0415a6255a75089501550081420abf0415a6255a7508950155"
    "0081420ac00416000026680175109501550081420ac104164cff26b40075109501550081420ac20415a6255a750895015500"
    "81420ac304150026feff7510950155008142c0c0c0"
)
PX13_LOST = bytes.fromhex(
    "0103020202640000003200000070173200000000005aa60a5aa60a1400140014500072006f00780069006d00690074007900"
    "2000530065006e0073006f007200300030003000300030003000300030003000300030003000300030003000300030003000"
    "30003000300030003000300030003000300030003000300030003000"
)
PX13_WORKING = bytes.fromhex(
    "0103020202320000003200000070173200c800b0045aa60a5aa60a0a000a000a500072006f00780069006d00690074007900"
    "2000530065006e0073006f007200300030003000300030003000300030003000300030003000300030003000300030003000"
    "30003000300030003000300030003000300030003000300030003000"
)


class SettingsTest(unittest.TestCase):
    GOOD = presenced.KNOWN_SETTINGS["13D3:52B9"]

    def places(self):
        fields, lengths = presenced.feature_fields(PX13_DESCRIPTOR)
        self.assertEqual(lengths[1], len(PX13_WORKING))
        return {usage: (offset, bits) for usage, (rid, offset, bits) in fields.items() if rid == 1}

    def test_the_descriptor_places_the_presence_threshold(self):
        fields, _ = presenced.feature_fields(PX13_DESCRIPTOR)
        rid, offset, bits = fields[0x74B1]
        self.assertEqual((rid, bits), (1, 16))
        value = int.from_bytes(PX13_WORKING, "little") >> offset & 0xFFFF
        self.assertEqual(value, 1200)

    def test_lost_settings_become_the_working_report(self):
        self.assertEqual(presenced.lost_settings(PX13_LOST, self.places(), self.GOOD), PX13_WORKING)

    def test_a_working_sensor_is_left_alone(self):
        self.assertIsNone(presenced.lost_settings(PX13_WORKING, self.places(), self.GOOD))

    def test_settings_chosen_on_purpose_are_left_alone(self):
        places = self.places()
        offset, _ = places[0x74B1]
        value = int.from_bytes(PX13_WORKING, "little")
        value = value & ~(0xFFFF << offset) | 800 << offset
        self.assertIsNone(presenced.lost_settings(value.to_bytes(len(PX13_WORKING), "little"), places, self.GOOD))

    def test_an_unknown_sensor_is_never_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = os.path.join(tmp, "0003:1234:5678.0001", "HID-SENSOR-200011.2.auto", "iio:device0")
            os.makedirs(device)
            os.makedirs(os.path.join(tmp, "0003:1234:5678.0001", "hidraw", "hidraw9"))
            settings = presenced.Settings(device)
            self.assertIsNone(settings.node)
            self.assertFalse(settings.repair())

    def test_a_known_sensor_is_found_by_its_usb_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            hid = os.path.join(tmp, "0003:13D3:52B9.0001")
            device = os.path.join(hid, "HID-SENSOR-200011.2.auto", "iio:device0")
            os.makedirs(device)
            os.makedirs(os.path.join(hid, "hidraw", "hidraw9"))
            with open(os.path.join(hid, "report_descriptor"), "wb") as handle:
                handle.write(PX13_DESCRIPTOR)
            settings = presenced.Settings(device)
            self.assertEqual(settings.node, "/dev/hidraw9")
            self.assertEqual((settings.report_id, settings.length), (1, len(PX13_WORKING)))

    def test_a_repair_restarts_the_first_wait(self):
        stall = presenced.Stall(0.0, first=20.0, longest=100.0)
        stall.cycled(20.0)
        stall.waited(60.0)
        self.assertFalse(stall.due(79.9, False))
        self.assertTrue(stall.due(80.0, False))


if __name__ == "__main__":
    unittest.main()
