#!/usr/bin/env python3
"""Synthetic negative tests for signed-guest offline preflight; no Apple binary."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

MODULE = Path(__file__).resolve().parent.parent / "Tools" / "verify-device-runtime.py"
spec = importlib.util.spec_from_file_location("verify_device_runtime", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def slot(kind, magic, data=b""):
    return struct.pack(">II", magic, len(data) + 8) + data


def superblob(with_cms=True):
    contents = [(0, slot(0, 0xfade0c02, b"CDIR"))]
    if with_cms:
        contents.append((0x10000, slot(0x10000, 0xfade0b01, b"ASN1")))
    count = len(contents)
    index = bytearray()
    data = bytearray()
    for kind, body in contents:
        index += struct.pack(">II", kind, 12 + count * 8 + len(data))
        data += body
    return struct.pack(">III", 0xfade0cc0, 12 + len(index) + len(data), count) + index + data


def macho(filetype=7, with_cms=True):
    signature = superblob(with_cms)
    header = struct.pack("<8I", 0xfeedfacf, 0x0100000c, 0, filetype, 1, 16, 0, 0)
    sig_command = struct.pack("<4I", 0x1d, 16, len(header) + 16, len(signature))
    return header + sig_command + signature


class PreflightTests(unittest.TestCase):
    def test_signed_dyld_header(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "dyld_sim"
            target.write_bytes(macho())
            record = mod.macho(target, 7)
            self.assertTrue(record["cms_present"])
            self.assertEqual(record["slots"], [0, 65536])

    def test_unsigned_dyld_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "dyld_sim"
            target.write_bytes(macho(with_cms=False))
            with self.assertRaisesRegex(ValueError, "Missing CodeDirectory or CMS"):
                mod.macho(target, 7)

    def test_wrong_filetype_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "launchd_sim"
            target.write_bytes(macho(filetype=7))
            with self.assertRaisesRegex(ValueError, "Expected thin arm64"):
                mod.macho(target, 2)

    def test_empty_root_not_device_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            result = mod.verify(Path(directory), "CI-ONLY", False)
            self.assertFalse(result["offline_checks_pass"])
            self.assertFalse(result["guest_boot_verified"])
            self.assertFalse(result["usb_extension_access_verified"])
            self.assertGreaterEqual(len(result["issues"]), 5)

    def test_symlinked_guest_binary_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "usr/lib").mkdir(parents=True)
            outside = root / "elsewhere"
            outside.write_bytes(macho())
            (root / "usr/lib/dyld_sim").symlink_to(outside)
            result = mod.verify(root, "CI-ONLY", False)
            self.assertTrue(any(i["stage"] == "usr/lib/dyld_sim" for i in result["issues"]))

    def test_overlapping_slots_rejected(self):
        data = bytearray(superblob())
        # Overwrite the second slot offset to collide with CodeDirectory.
        data[24:28] = data[16:20]
        with self.assertRaises(ValueError):
            mod.signature_slots(data)


if __name__ == "__main__":
    unittest.main()
