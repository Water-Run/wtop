#!/usr/bin/env python3
"""Regression controls for release transport loss, corruption and permissions."""

import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import sys

from installed_smoke import run_checks


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_archive", ROOT / "tools/release_archive.py")
archive_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive_tool)


class ReleaseArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wtop-transport-test-")
        self.root = Path(self.temporary.name)
        self.dist = self.root / "dist"
        self.files = {name: (name + " fixture\n").encode() for name in archive_tool.REQUIRED}
        self.files["BASELINE.release.txt"] = b"status: within the promised floor\n"
        hashed = {name: data for name, data in self.files.items()
                  if name.startswith("wtop/") or name == "wtop-onefile"}
        self.files["SHA256SUMS"] = archive_tool.manifest_bytes(hashed)
        self.files["SBOM.cyclonedx.json"] = json.dumps({"components": [{"hashes": [
            {"alg": "SHA-256", "content": archive_tool.digest(data)}
            for data in hashed.values()]}]}).encode()
        for name, data in self.files.items():
            path = self.dist / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755 if name in ("wtop/wtop", "wtop-onefile",
                                        "wtop/.luai/native/wtop_native.so") else 0o644)
        self.archive = self.root / "wtop-test-linux-x86_64-glibc.tar.gz"
        archive_tool.create(self.dist, self.archive)

    def tearDown(self):
        self.temporary.cleanup()

    def rewrite(self, mutate):
        files, modes = archive_tool.inspect(self.archive)
        mutate(files, modes)
        with tarfile.open(self.archive, "w:gz") as output:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size, member.mode = len(data), modes[name]
                output.addfile(member, io.BytesIO(data))

    def test_hidden_payload_and_modes_survive(self):
        files, modes = archive_tool.inspect(self.archive)
        self.assertEqual(files["wtop/.luai/native/wtop_native.so"],
                         self.files["wtop/.luai/native/wtop_native.so"])
        self.assertEqual(modes["wtop/wtop"], 0o755)
        second = self.root / "second.tar.gz"
        archive_tool.create(self.dist, second)
        self.assertEqual(self.archive.read_bytes(), second.read_bytes())

    def test_missing_hidden_module_is_rejected(self):
        self.rewrite(lambda files, modes: files.pop("wtop/.luai/native/wtop_native.so"))
        with self.assertRaisesRegex(ValueError, "manifest"):
            archive_tool.inspect(self.archive)

    def test_changed_module_is_rejected(self):
        self.rewrite(lambda files, modes: files.update({"wtop/.luai/native/wtop_native.so": b"changed"}))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            archive_tool.inspect(self.archive)

    def test_execute_permission_loss_is_rejected(self):
        self.rewrite(lambda files, modes: modes.update({"wtop/wtop": 0o644}))
        with self.assertRaisesRegex(ValueError, "permissions"):
            archive_tool.inspect(self.archive)

    def test_symlinks_are_rejected(self):
        target = self.dist / "wtop/.luai/native/wtop_native.so"
        target.unlink()
        target.symlink_to(self.root / "elsewhere")
        with self.assertRaisesRegex(ValueError, "symlink"):
            archive_tool.create(self.dist, self.root / "bad.tar.gz")

    def test_archive_path_escape_is_rejected(self):
        self.rewrite(lambda files, modes: (files.update({"../escape": b"x"}),
                                          modes.update({"../escape": 0o644})))
        with self.assertRaisesRegex(ValueError, "unsafe"):
            archive_tool.inspect(self.archive)

    def test_stale_download_digest_is_rejected(self):
        self.archive.with_name(self.archive.name + ".sha256").write_text(
            "0" * 64 + "  " + self.archive.name + "\n")
        with self.assertRaisesRegex(ValueError, "downloaded archive digest"):
            archive_tool.verify(self.archive, ROOT, "0.2.0", "quick")

    def test_installed_empty_native_version_is_rejected(self):
        executable = self.root / "fake-wtop"
        executable.write_text("#!" + sys.executable + "\nimport sys\n"
                              "if '--version' in sys.argv: print('wtop 0.2.0')\n"
                              "else: print('  Platform: Linux test\\n  Native:   available ()')\n")
        executable.chmod(0o755)
        with self.assertRaisesRegex(AssertionError, "native version"):
            run_checks(executable, "0.2.0", "Linux")


if __name__ == "__main__":
    unittest.main()
