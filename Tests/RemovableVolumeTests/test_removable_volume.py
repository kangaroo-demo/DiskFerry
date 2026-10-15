"""Test USB verifier boundaries without opening any device or real volume."""
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("removable", ROOT / "Scripts/verify-removable-volume.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class VerifierBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.sandbox = self.root / "payload"
        self.sandbox.mkdir()
        self.fd = os.open(self.sandbox, os.O_RDONLY | os.O_DIRECTORY)

    def tearDown(self):
        os.close(self.fd)
        self.temporary.cleanup()

    def test_device_argument_never_accepts_a_path_or_shell_text(self):
        for device in ("/dev/disk8", "disk8;id", "../disk8", "disk8\n", "disk8s"):
            with self.subTest(device=device), patch.object(VERIFIER, "execute") as execute:
                with self.assertRaises(ValueError):
                    VERIFIER.info(device)
                execute.assert_not_called()

    def test_paths_cannot_escape_the_retained_directory(self):
        for name in ("/escape", "../escape", "a/../../escape", "", "."):
            with self.subTest(name=name), self.assertRaises(ValueError):
                VERIFIER.put(self.fd, name, [b"forbidden"])
        self.assertEqual(list(self.sandbox.iterdir()), [])

    def test_symlink_parent_cannot_redirect_a_write(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.sandbox / "redirect").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            VERIFIER.put(self.fd, "redirect/escape", [b"forbidden"])
        self.assertEqual(list(outside.iterdir()), [])

    def test_existing_file_or_symlink_is_never_overwritten(self):
        outside = self.root / "original"
        outside.write_bytes(b"KEEP")
        (self.sandbox / "link").symlink_to(outside)
        (self.sandbox / "existing").write_bytes(b"ORIGINAL")
        for name in ("link", "existing"):
            with self.subTest(name=name), self.assertRaises(FileExistsError):
                VERIFIER.put(self.fd, name, [b"forbidden"])
        self.assertEqual(outside.read_bytes(), b"KEEP")
        self.assertEqual((self.sandbox / "existing").read_bytes(), b"ORIGINAL")

    def test_verification_refuses_symlink_and_fifo_payloads(self):
        outside = self.root / "secret"
        outside.write_bytes(b"do not follow")
        (self.sandbox / "link").symlink_to(outside)
        with self.assertRaises(OSError):
            VERIFIER.digest(self.fd, "link")
        os.mkfifo(self.sandbox / "fifo")
        with self.assertRaisesRegex(ValueError, "not a regular file"):
            VERIFIER.digest(self.fd, "fifo")

    def test_missing_path_check_cannot_follow_a_parent_symlink(self):
        (self.sandbox / "redirect").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            VERIFIER.check(self.fd, [], ["redirect/missing"])

    def test_retained_directory_survives_path_replacement(self):
        retained = self.root / "retained"
        self.sandbox.rename(retained)
        self.sandbox.mkdir()
        VERIFIER.put(self.fd, "test", [b"only in retained directory"])
        self.assertEqual(list(self.sandbox.iterdir()), [])
        self.assertEqual((retained / "test").read_bytes(), b"only in retained directory")

    def test_identity_change_stops_test(self):
        expected = dict(id="disk8s1", volumeUUID="test-only", liveIdentity=1)
        changed = dict(expected, liveIdentity=2)
        with patch.object(VERIFIER, "inspect", return_value=(changed, self.sandbox)):
            with self.assertRaisesRegex(ValueError, "identity changed"):
                VERIFIER.recheck(expected)

    def test_internal_or_virtual_or_wrong_uuid_disk_is_rejected(self):
        volume = dict(ParentWholeDisk="disk8", Internal=False, WritableVolume=True, VolumeUUID="approved")
        whole = dict(Internal=False, WholeDisk=True, VirtualOrPhysical="Physical", BusProtocol="USB")
        for vol_change, disk_change in ((dict(Internal=True), {}), ({}, dict(Internal=True)),
                                        ({}, dict(VirtualOrPhysical="Virtual")),
                                        ({}, dict(BusProtocol="SATA")),
                                        (dict(VolumeUUID="other"), {}),
                                        (dict(WritableVolume=False), {})):
            with self.subTest(volume=vol_change, whole=disk_change):
                with patch.object(VERIFIER, "info", side_effect=[dict(volume, **vol_change), dict(whole, **disk_change)]):
                    with self.assertRaises(ValueError):
                        VERIFIER.inspect("disk8s1", "approved", require_write=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
