"""The release bundler must build the same dependency that was tested."""
import os
import plistlib
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
                "build", "--release=safe", "-j1", "--fork=/synthetic/nanoui", "-j1",
            ])


class BundleVersionTests(unittest.TestCase):
    def bundle(self, manifest):
        source = Path(__file__).with_name("bundle.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nano = root / "apps/nano"
            (nano / "scripts").mkdir(parents=True)
            (root / "bin").mkdir()
            (root / "Cargo.toml").write_text(manifest)
            script = nano / "scripts/bundle.sh"
            script.write_bytes(source.read_bytes())
            zig = root / "bin/zig"
            zig.write_text('#!/bin/sh\nmkdir -p zig-out/bin\nprintf synthetic > zig-out/bin/harness-nano\n')
            zig.chmod(0o755)
            signer = root / "bin/codesign"
            signer.write_text('#!/bin/sh\ntest -f "zig-out/Harness Nano.app/Contents/Info.plist"\n')
            signer.chmod(0o755)
            result = subprocess.run(
                ["sh", str(script)],
                env={**os.environ, "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"]},
                capture_output=True,
                text=True,
            )
            info = nano / "zig-out/Harness Nano.app/Contents/Info.plist"
            return result, plistlib.loads(info.read_bytes()) if info.exists() else None

    def test_bundle_versions_match_the_workspace_not_another_package(self):
        result, info = self.bundle(
            '[package]\nversion = "1.2.3"\n'
            '[workspace.package]\nversion = "9.8.7"\n'
            '[workspace.dependencies]\nversion = "4.5.6"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(info["CFBundleVersion"], "9.8.7")

    def test_missing_workspace_version_does_not_ship_a_placeholder(self):
        result, info = self.bundle('[package]\nversion = "1.2.3"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("workspace version", result.stderr)
        self.assertIsNone(info)


if __name__ == "__main__":
    unittest.main()
