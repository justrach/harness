"""Synthetic renderer paths: import scripts without renderers or image dependencies."""
import importlib.util
import os
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


REPO = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS = (
    ("apps/nano/parity/check.py", "HARNESS_UI_SCENES", "ui-scenes"),
    ("apps/nano/bench/resource.py", "HARNESS_RESOURCE_PROFILE", "macos-resource-profile"),
)


class RendererPathTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.addCleanup(os.chdir, pathlib.Path.cwd())
        self.unrelated = pathlib.Path(directory.name)
        self.home = self.unrelated / "synthetic-home"
        os.chdir(self.unrelated)

    def load(self, script, overrides):
        # Neither optional image package is needed to resolve paths. Stub only
        # those imports; execute each entire script under a non-main name.
        pil = types.ModuleType("PIL")
        pil.Image = types.ModuleType("PIL.Image")
        dependencies = {"numpy": types.ModuleType("numpy"), "PIL": pil,
                        "PIL.Image": pil.Image}
        spec = importlib.util.spec_from_file_location("renderer_path_probe", REPO / script)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {"HOME": str(self.home), **overrides}, clear=True):
            with patch.dict(sys.modules, dependencies):
                spec.loader.exec_module(module)
        return module

    def test_defaults_are_checkout_local_from_unrelated_cwd(self):
        for script, variable, binary in SCRIPTS:
            with self.subTest(script=script):
                module = self.load(script, {})
                self.assertEqual(module.GPUI_BIN, REPO / "target/app-dev/examples" / binary)

    def test_absolute_overrides_are_preserved(self):
        for script, variable, binary in SCRIPTS:
            with self.subTest(script=script):
                override = self.unrelated / "custom-renderers" / binary
                module = self.load(script, {variable: str(override)})
                self.assertEqual(module.GPUI_BIN, override)

    def test_home_overrides_are_expanded(self):
        for script, variable, binary in SCRIPTS:
            with self.subTest(script=script):
                module = self.load(script, {variable: f"~/custom-renderers/{binary}"})
                self.assertEqual(module.GPUI_BIN, self.home / "custom-renderers" / binary)


if __name__ == "__main__":
    unittest.main()
