"""The release bundler must build the same dependency that was tested."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BundleArgumentsTests(unittest.TestCase):
    def test_dependency_override_and_build_options_reach_zig(self):
        source = Path(__file__).with_name("bundle.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            script = root / "scripts/bundle.sh"
            script.write_bytes(source.read_bytes())
            zig = root / "bin/zig"
            # Stop before packaging: no compiler, installed app, or real data.
            zig.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 73\n')
            zig.chmod(0o755)
            result = subprocess.run(
                ["sh", str(script), "--fork=/synthetic/nanoui", "-j1"],
                env={**os.environ, "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"]},
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                "build", "-Doptimize=ReleaseSafe", "--fork=/synthetic/nanoui", "-j1",
            ])


if __name__ == "__main__":
    unittest.main()
