#!/usr/bin/env python3
"""Synthetic regression tests; no compiler, shared build lock, or user data."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


WRAPPER = Path(__file__).resolve().with_name("heavy-build.sh")
# The owner cannot hang the suite if a regression prevents its release.
HOLD_COMMAND = """
from pathlib import Path
import sys, time
started, release = map(Path, sys.argv[1:])
started.touch()
deadline = time.monotonic() + 10
while not release.exists():
    if time.monotonic() > deadline:
        sys.exit(98)
    time.sleep(0.01)
"""


class HeavyBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="heavy-build-test-")
        self.root = Path(self.temp.name)
        self.lock = self.root / "slot.lock"
        self.wait_dir = self.root / "wait"
        self.wait_dir.mkdir()
        self.processes = []
        self.env = os.environ.copy()
        self.env.update(
            HARNESS_HEAVY_BUILD_LOCK=str(self.lock),
            HARNESS_BUILD_WAIT_DIR=str(self.wait_dir),
            HARNESS_HEAVY_BUILD_POLL_INTERVAL="0.03",
        )

    def tearDown(self):
        # Kill only the synthetic process groups started by this test.
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)
        self.temp.cleanup()

    def start(self, code, *args, with_wait_dir=True):
        env = self.env.copy()
        if not with_wait_dir:
            env.pop("HARNESS_BUILD_WAIT_DIR", None)
        process = subprocess.Popen(
            ["bash", str(WRAPPER), sys.executable, "-c", code, *map(str, args)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.processes.append(process)
        return process

    def wait_for(self, predicate, message):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        self.fail(message)

    def finish(self, process, expected=0):
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, expected, (stdout, stderr))
        self.assertEqual((stdout, stderr), (b"", b""), "wrapper must stay quiet")

    def hold_slot(self):
        started = self.root / "owner-started"
        release = self.root / "owner-release"
        owner = self.start(HOLD_COMMAND, started, release)
        self.wait_for(started.exists, "synthetic owner never acquired the slot")
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        return owner, release

    def wait_marker(self, process):
        marker = self.wait_dir / str(process.pid)
        self.wait_for(marker.exists, "contended wrapper did not publish a wait marker")
        self.wait_for(lambda: bool(marker.read_text().strip()), "empty wait marker")
        return marker

    def test_contention_marker_is_stable_and_acquisition_clears_it(self):
        owner, owner_release = self.hold_slot()
        waiter_started = self.root / "waiter-started"
        waiter_release = self.root / "waiter-release"
        before = int(time.time())
        waiter = self.start(HOLD_COMMAND, waiter_started, waiter_release)
        marker = self.wait_marker(waiter)
        timestamp = marker.read_text().strip()
        self.assertTrue(timestamp.isdecimal())
        self.assertLessEqual(before, int(timestamp))
        self.assertLessEqual(int(timestamp), int(time.time()))
        self.assertFalse(waiter_started.exists(), "two commands ran at once")
        # Cross a Unix-second boundary and many polling retries.
        time.sleep(1.1)
        self.assertEqual(marker.read_text().strip(), timestamp)
        self.assertEqual(sorted(p.name for p in self.wait_dir.iterdir()), [str(waiter.pid)])
        owner_release.touch()
        self.finish(owner)
        self.wait_for(waiter_started.exists, "queued command never acquired the slot")
        self.assertFalse(marker.exists(), "marker survived lock acquisition")
        self.assertEqual((self.lock / "pid").read_text().strip(), str(waiter.pid))
        waiter_release.touch()
        self.finish(waiter)
        self.assertFalse(self.lock.exists())

    def check_queued_cancellation(self, sig):
        owner, release = self.hold_slot()
        waiter = self.start("raise SystemExit(97)")
        marker = self.wait_marker(waiter)
        waiter.send_signal(sig)
        self.finish(waiter, 128 + sig)
        self.assertFalse(marker.exists(), "cancelled wait marker survived")
        self.assertIsNone(owner.poll())
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        release.touch()
        self.finish(owner)
        self.assertFalse(self.lock.exists())

    def test_queued_term_keeps_owners_lock(self):
        self.check_queued_cancellation(signal.SIGTERM)

    def test_queued_int_keeps_owners_lock(self):
        self.check_queued_cancellation(signal.SIGINT)

    def test_command_failure_releases_slot_and_preserves_status(self):
        failed = self.start("raise SystemExit(23)")
        self.finish(failed, 23)
        self.assertFalse(self.lock.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        following = self.start("pass")
        self.finish(following)
        self.assertFalse(self.lock.exists())

    def test_uncontended_command_never_has_marker(self):
        started = self.root / "started"
        release = self.root / "release"
        process = self.start(HOLD_COMMAND, started, release)
        self.wait_for(started.exists, "uncontended command did not start")
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        release.touch()
        self.finish(process)
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        self.assertFalse(self.lock.exists())

    def test_retired_wait_directory_is_not_recreated(self):
        owner, release = self.hold_slot()
        self.wait_dir.rmdir()
        waiter = self.start("pass")
        time.sleep(0.15)
        self.assertFalse(self.wait_dir.exists(), "a retired run's private directory was recreated")
        self.assertIsNone(waiter.poll())
        release.touch()
        self.finish(owner)
        self.finish(waiter)

    def test_no_wait_directory_does_not_publish_marker(self):
        owner, release = self.hold_slot()
        started = self.root / "without-marker-started"
        waiter = self.start("from pathlib import Path; import sys; Path(sys.argv[1]).touch()", started,
                            with_wait_dir=False)
        time.sleep(0.15)
        self.assertIsNone(waiter.poll())
        self.assertFalse(started.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        release.touch()
        self.finish(owner)
        # The original wrapper polls every five seconds; this test also runs on it.
        stdout, stderr = waiter.communicate(timeout=7)
        self.assertEqual((waiter.returncode, stdout, stderr), (0, b"", b""))
        self.assertTrue(started.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        self.assertFalse(self.lock.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
