import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "memory_probe", Path(__file__).resolve().parents[1] / "scripts/measure-memory.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class MemoryProbeTests(unittest.TestCase):
    def test_physical_footprint_units_and_peak_exclusion(self):
        for value, expected in [("2048K", 2), ("42.5M", 42.5), ("1.2G", 1228.8),
                                ("1048576", 1)]:
            self.assertAlmostEqual(probe.physical_mib(
                "Physical footprint:  " + value + "\nPhysical footprint (peak): 9G\n"), expected)

    def test_empty_and_invalid_reports_fail_closed(self):
        for value in ("", "Physical footprint (peak): 9G", "Physical footprint: unknown"):
            with self.assertRaises(ValueError):
                probe.physical_mib(value)

    def test_both_metrics_enforced_and_boundary_allowed(self):
        budget = {"footprint_mib": 30, "rss_mib": 100}
        self.assertFalse(probe.over_budget(dict(budget), budget))
        for key in budget:
            row = dict(budget)
            row[key] += 0.1
            self.assertTrue(probe.over_budget(row, budget))
            row[key] = float("nan")
            self.assertTrue(probe.over_budget(row, budget))

    def test_missing_measurements_fail(self):
        with self.assertRaises(KeyError):
            probe.over_budget({}, {"footprint_mib": 30, "rss_mib": 100})


if __name__ == "__main__":
    unittest.main()
