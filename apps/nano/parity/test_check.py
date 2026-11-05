"""The strict parity ceiling covers new frames, not only recorded budgets."""
import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("nano_parity_check", pathlib.Path(__file__).with_name("check.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class StrictParityTests(unittest.TestCase):
    def run_check(self, changed, budget=None, update=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            scene = root / "scene.json"
            scene.write_text(json.dumps({"name": "synthetic"}))
            budgets = root / "budget.json"
            original = {} if budget is None else {"synthetic.png": budget}
            budgets.write_text(json.dumps(original))
            renderer = root / "renderer"
            renderer.touch()
            args = ["check.py", str(scene), "--out", str(root / "out"), "--max-changed", "0.0005"]
            if update:
                args.append("--update")
            result = {"changed": changed, "exact": changed, "mae": changed}
            with mock.patch.object(check, "GPUI_BIN", renderer), mock.patch.object(check, "BUDGET", budgets), \
                    mock.patch.object(check, "run"), mock.patch.object(check, "compare", return_value=result), \
                    mock.patch("sys.argv", args), contextlib.redirect_stdout(io.StringIO()):
                try:
                    check.main()
                except SystemExit as error:
                    status = error.code
                else:
                    status = 0
            return status, json.loads((root / "out/report.json").read_text()), json.loads(budgets.read_text())

    def test_new_frame_cannot_bypass_the_absolute_ceiling(self):
        status, report, _ = self.run_check(0.001)
        self.assertNotEqual(status, 0)
        self.assertEqual(report["failed"], ["synthetic.png"])
        self.assertEqual(report["meanChanged"], 0.001)

    def test_update_cannot_record_a_frame_above_the_ceiling(self):
        status, _, budget = self.run_check(0.001, update=True)
        self.assertNotEqual(status, 0)
        self.assertEqual(budget, {})

    def test_ceiling_checks_unrounded_values(self):
        status, _, _ = self.run_check(0.000501, budget=0.0005)
        self.assertNotEqual(status, 0)

    def test_frame_within_both_limits_passes(self):
        status, report, _ = self.run_check(0.00049, budget=0.0004)
        self.assertEqual(status, 0)
        self.assertEqual(report["failed"], [])


if __name__ == "__main__":
    unittest.main()
