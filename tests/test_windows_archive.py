#!/usr/bin/env python3
"""Check Windows ZIP payload integrity and executable metadata across hosts."""
from pathlib import Path
import hashlib
import os
import stat
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import package_windows as Package


class WindowsArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wtop-windows-archive-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "bundle"
        self.files = {
            "wtop/wtop.exe": b"MZ directory launcher",
            "wtop/lua55.dll": b"MZ Lua library",
            "wtop/.luai/native/wtop_native.dll": b"MZ native library",
            "wtop-onefile.exe": b"MZ onefile launcher",
            "wtop/.luai/lua/wtop/version.lua": b"return '0.2.0'\n",
        }
        for name in Package.WINDOWS_ARCHIVE_REQUIRED:
            self.files.setdefault(name, (name + " notice\n").encode())
        for name, data in self.files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o600)  # Windows stat/copy modes cannot supply this contract.
        self.output = self.root / "wtop-windows-x86.zip"

    def tearDown(self):
        self.temporary.cleanup()

    def test_contents_hidden_payload_and_loader_permissions(self):
        Package.create_archive(self.source, self.output)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(set(archive.namelist()), set(self.files))
            for entry in archive.infolist():
                self.assertEqual(archive.read(entry), self.files[entry.filename])
                self.assertEqual(entry.create_system, 3)
                self.assertEqual(entry.date_time, (1980, 1, 1, 0, 0, 0))
                expected = 0o755 if entry.filename.endswith((".exe", ".dll")) else 0o644
                self.assertEqual(stat.S_IMODE(entry.external_attr >> 16), expected)
        self.assertEqual(Path(str(self.output) + ".sha256").read_text(),
                         hashlib.sha256(self.output.read_bytes()).hexdigest() + "  " + self.output.name + "\n")

    def test_source_modes_and_mtimes_do_not_change_archive(self):
        Package.create_archive(self.source, self.output)
        first = self.output.read_bytes()
        for path in self.source.rglob("*"):
            if path.is_file():
                path.chmod(0o777)
                os.utime(path, (1609459200, 1609459200))
        second = self.root / "second.zip"
        Package.create_archive(self.source, second)
        self.assertEqual(first, second.read_bytes())

    def test_missing_required_payload_is_rejected(self):
        (self.source / "wtop/lua55.dll").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            Package.create_archive(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_symlink_is_rejected_without_replacing_existing_archive(self):
        link = self.source / "outside"
        try:
            link.symlink_to(self.root / "external")
        except OSError:
            if os.name == "nt":
                self.skipTest("this Windows account cannot create a test symlink")
            raise
        self.output.write_bytes(b"old archive")
        with self.assertRaisesRegex(ValueError, "symlink"):
            Package.create_archive(self.source, self.output)
        self.assertEqual(self.output.read_bytes(), b"old archive")

    def test_output_inside_payload_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "inside"):
            Package.create_archive(self.source, self.source / "nested.zip")

    def test_non_pe_executable_is_rejected(self):
        (self.source / "wtop/wtop.exe").write_bytes(b"text with an exe suffix")
        with self.assertRaisesRegex(ValueError, "PE"):
            Package.create_archive(self.source, self.output)


if __name__ == "__main__":
    unittest.main()
