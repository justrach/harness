"""Synthetic samples only: phase peaks must include the warmup window."""
import importlib.util
import json
import pathlib
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nano_resource", pathlib.Path(__file__).with_name("resource.py"))
resource = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resource)


def sample(at, phase, footprint, cpu, wakeups):
    return {
        "at": at,
        "phase": phase,
        "footprintMiB": footprint,
        "rssMiB": footprint / 2,
        "cpuSeconds": cpu,
        "idleWakeups": wakeups,
        "lifetimePeakFootprintMiB": 1000,
    }


class ResourceSampleTests(unittest.TestCase):
    def test_exiting_process_zero_footprint_is_not_a_resting_sample(self):
        for footprint in (64, 0):
            row = sample(15, "settled", footprint, 2, 0)
            # proc_pid_rusage can retain RSS while physical footprint is zero
            # at process exit; that is not the app's settled memory usage.
            row["rssMiB"] = 124
            with self.subTest(footprint=footprint), patch.object(
                resource.subprocess, "run",
                return_value=SimpleNamespace(stdout=json.dumps([row])),
            ):
                result = resource.stat(pathlib.Path("synthetic-sampler"), 123)
                if footprint:
                    self.assertEqual(result, row)
                else:
                    self.assertIsNone(result)


class ResourceSummaryTests(unittest.TestCase):
    def test_phase_peaks_include_warmup_but_cpu_and_wakeups_do_not(self):
        rows = [
            sample(0, "replay", 100, 0, 0),
            sample(1, "replay", 900, 0.8, 20),
            sample(2, "replay", 90, 1, 30),
            sample(3, "replay", 80, 1.1, 31),
            sample(4, "replay", 70, 1.2, 32),
        ]
        report = resource.summarize(rows)
        replay = report["replay"]
        self.assertEqual(replay["peakFootprintMiB"], 900)
        self.assertEqual(replay["peakRssMiB"], 450)
        self.assertEqual(replay["endFootprintMiB"], 70)
        self.assertEqual(replay["endRssMiB"], 35)
        self.assertEqual(replay["cpuPercent"], 10)
        self.assertEqual(replay["idleWakeupsPerSecond"], 1)
        self.assertEqual(replay["durationSeconds"], 2)
        self.assertEqual(report["lifetimePeakFootprintMiB"], 1000)
        self.assertEqual(report["totalCpuSeconds"], 1.2)

    def test_settling_spike_belongs_only_to_settled_phase(self):
        rows = [
            sample(0, "startup", 950, 0, 0),
            sample(1, "replay", 90, 0.1, 1),
            sample(3, "replay", 80, 0.3, 3),
            sample(5, "replay", 70, 0.5, 5),
            sample(6, "settled", 900, 0.6, 6),
            sample(8, "settled", 60, 0.8, 8),
            sample(10, "settled", 50, 1, 10),
        ]
        report = resource.summarize(rows)
        self.assertEqual(report["replay"]["peakFootprintMiB"], 90)
        self.assertEqual(report["settled"]["peakFootprintMiB"], 900)
        self.assertEqual(report["settled"]["peakRssMiB"], 450)
        self.assertEqual(report["settled"]["endFootprintMiB"], 50)
        self.assertEqual(report["settled"]["cpuPercent"], 10)

    def test_short_phase_uses_all_available_samples(self):
        report = resource.summarize([
            sample(0, "settled", 90, 0, 0),
            sample(0.5, "settled", 60, 0.1, 1),
        ])
        self.assertNotIn("replay", report)
        self.assertEqual(report["settled"]["peakFootprintMiB"], 90)
        self.assertEqual(report["settled"]["cpuPercent"], 20)
        self.assertEqual(report["settled"]["idleWakeupsPerSecond"], 2)


if __name__ == "__main__":
    unittest.main()
