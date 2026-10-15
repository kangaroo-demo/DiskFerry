"""Real NTFS image tests for the callback bridge; no devices or FSKit mount.

Run with Python 3 after Scripts/prepare-ntfs-core.sh. Only freshly created
regular files inside .build are opened. No raw-device test argument exists.
"""
import ctypes as c
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / ".build/vendor/ntfs-3g-2026.9.28"
SOURCE = ROOT / "Extensions/DiskFerryNTFS/bridge"
BUILD = ROOT / ".build/ntfs-bridge-tests"
READ = c.CFUNCTYPE(c.c_longlong, c.c_void_p, c.c_void_p, c.c_longlong, c.c_longlong)
SYNC = c.CFUNCTYPE(c.c_int, c.c_void_p)


class IO(c.Structure):
    _fields_ = [("ctx", c.c_void_p), ("pread", READ), ("pwrite", READ), ("sync", SYNC),
                ("size", c.c_longlong), ("readonly", c.c_int)]


def build_bridge():
    BUILD.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-O1", "-g", "-Wall", "-Wextra",
                    "-DHAVE_CONFIG_H=1", "-include", str(ENGINE / "config.h"),
                    "-I", str(ENGINE), "-I", str(ENGINE / "include"), "-I", str(ENGINE / "include/ntfs-3g"),
                    str(SOURCE / "ntfs_bridge.c"), str(ENGINE / "libntfs-3g/.libs/libntfs-3g.a"),
                    "-framework", "CoreFoundation", "-o", str(BUILD / "bridge.dylib")],
                   env=env, check=True, timeout=120)
    lib = c.CDLL(str(BUILD / "bridge.dylib"), use_errno=True)
    signatures = {
        "nk_mount_io": (c.c_void_p, [c.POINTER(IO), c.c_char_p, c.c_size_t]),
        "nk_umount": (c.c_int, [c.c_void_p]),
        "nk_create": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "nk_mkdir": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "nk_delete": (c.c_int, [c.c_void_p, c.c_char_p]),
        "nk_rename": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p]),
        "nk_truncate": (c.c_int, [c.c_void_p, c.c_char_p, c.c_longlong]),
        "nk_read": (c.c_longlong, [c.c_void_p, c.c_char_p, c.c_longlong, c.c_longlong, c.c_void_p]),
        "nk_write": (c.c_longlong, [c.c_void_p, c.c_char_p, c.c_longlong, c.c_longlong, c.c_void_p]),
        "nk_sync": (c.c_int, [c.c_void_p]),
        "nk_fsck": (c.c_int, [c.POINTER(IO), c.c_int, c.c_char_p, c.c_size_t]),
        "nk_xattr_set": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_void_p, c.c_longlong]),
        "nk_xattr_get": (c.c_longlong, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_void_p, c.c_longlong]),
        "nk_xattr_remove": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "nk_set_label": (c.c_int, [c.c_void_p, c.c_char_p]),
        "nk_set_times": (c.c_int, [c.c_void_p, c.c_char_p, c.c_longlong, c.c_longlong, c.c_longlong]),
    }
    for name, (result, arguments) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result, arguments
    return lib


class ImageIO:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        self.size = os.fstat(self.fd).st_size
        if not stat.S_ISREG(os.fstat(self.fd).st_mode):
            os.close(self.fd)
            raise ValueError("Only ordinary test images are allowed")
        self.writes = self.syncs = 0
        self.fail_read = self.fail_write = self.fail_sync = False

        def read(_context, destination, count, offset):
            if self.fail_read:
                return 0
            try:
                data = os.pread(self.fd, count, offset)
                c.memmove(destination, data, len(data))
                return len(data)
            except OSError:
                return -1

        def write(_context, source, count, offset):
            self.writes += 1
            if self.fail_write:
                return -1
            try:
                return os.pwrite(self.fd, c.string_at(source, count), offset)
            except OSError:
                return -1

        def sync(_context):
            self.syncs += 1
            if self.fail_sync:
                return -1
            os.fsync(self.fd)
            return 0

        self.read, self.write, self.sync = READ(read), READ(write), SYNC(sync)
        self.io = IO(None, self.read, self.write, self.sync, self.size, 0)

    def close(self):
        os.close(self.fd)


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = build_bridge()
        cls.template = BUILD / "fresh.ntfs"
        with cls.template.open("wb") as stream:
            stream.truncate(64 * 1024 * 1024)
        subprocess.run([str(ENGINE / "ntfsprogs/mkntfs"), "-F", "-Q", "-L", "DISKFERRY_TEST",
                        str(cls.template)], check=True, capture_output=True, timeout=60)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="case-", dir=BUILD)
        self.path = Path(self.temporary.name) / "disposable.ntfs"
        shutil.copyfile(self.template, self.path)
        self.device = ImageIO(self.path)
        self.volume = None

    def tearDown(self):
        if self.volume:
            self.lib.nk_umount(self.volume)
        self.device.close()
        self.temporary.cleanup()

    def mount(self, readonly=False):
        self.device.io.readonly = int(readonly)
        error = c.create_string_buffer(256)
        self.volume = self.lib.nk_mount_io(c.byref(self.device.io), error, len(error))
        self.assertTrue(self.volume, error.value.decode(errors="replace"))

    def unmount(self):
        volume, self.volume = self.volume, None
        return self.lib.nk_umount(volume)

    def read(self, path, size, offset=0):
        data = c.create_string_buffer(size)
        count = self.lib.nk_read(self.volume, path, offset, size, data)
        self.assertGreaterEqual(count, 0)
        return data.raw[:count]

    def test_unicode_random_write_truncate_rename_and_persistence(self):
        self.mount()
        self.assertEqual(self.lib.nk_mkdir(self.volume, b"/", "目录".encode()), 0)
        self.assertEqual(self.lib.nk_create(self.volume, "/目录".encode(), "文件 😀.bin".encode()), 0)
        path = "/目录/文件 😀.bin".encode()
        payload = bytearray(hashlib.shake_256(b"diskferry").digest(2 * 1024 * 1024))
        self.assertEqual(self.lib.nk_write(self.volume, path, 0, len(payload), bytes(payload)), len(payload))
        self.assertEqual(self.lib.nk_write(self.volume, path, 4093, 7, b"CHANGED"), 7)
        payload[4093:4100] = b"CHANGED"
        self.assertEqual(self.lib.nk_truncate(self.volume, path, 100001), 0)
        self.assertEqual(self.read(path, len(payload)), bytes(payload[:100001]))
        self.assertEqual(self.lib.nk_rename(self.volume, path, "/目录".encode(), b"renamed.bin"), 0)
        self.assertEqual(self.lib.nk_sync(self.volume), 0)
        self.assertGreater(self.device.syncs, 0)
        self.assertEqual(self.unmount(), 0)
        self.mount(readonly=True)
        self.assertEqual(self.read("/目录/renamed.bin".encode(), len(payload)), bytes(payload[:100001]))

    def test_sparse_gap_zero_and_empty_truncate(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"gap.bin"), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/gap.bin", 65539, 4, b"TAIL"), 4)
        self.assertEqual(self.read(b"/gap.bin", 65543), bytes(65539) + b"TAIL")
        self.assertEqual(self.lib.nk_truncate(self.volume, b"/gap.bin", 0), 0)
        self.assertEqual(self.read(b"/gap.bin", 32), b"")

    def test_readonly_mount_performs_no_writes_and_refuses_mutation(self):
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.mount(readonly=True)
        self.assertNotEqual(self.lib.nk_create(self.volume, b"/", b"forbidden"), 0)
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.device.writes, 0)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_all_mutation_paths_refuse_readonly_volume(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/original", 0, 4, b"KEEP"), 4)
        self.assertEqual(self.unmount(), 0)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.mount(readonly=True)
        operations = [
            lambda: self.lib.nk_write(self.volume, b"/original", 0, 3, b"BAD"),
            lambda: self.lib.nk_truncate(self.volume, b"/original", 0),
            lambda: self.lib.nk_rename(self.volume, b"/original", b"/", b"renamed"),
            lambda: self.lib.nk_delete(self.volume, b"/original"),
            lambda: self.lib.nk_mkdir(self.volume, b"/", b"directory"),
            lambda: self.lib.nk_set_times(self.volume, b"/original", 1, 1, 1),
            lambda: self.lib.nk_set_label(self.volume, b"CHANGED"),
            lambda: self.lib.nk_xattr_set(self.volume, b"/original", b"test", b"BAD", 3),
            lambda: self.lib.nk_xattr_remove(self.volume, b"/original", b"test"),
        ]
        for operation in operations:
            self.assertEqual(operation(), -1)
        self.assertEqual(self.read(b"/original", 16), b"KEEP")
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_missing_sync_refuses_writable_mount_before_any_write(self):
        self.device.io.sync = SYNC()
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
        self.assertEqual(self.device.writes, 0)

    def test_failed_sync_is_propagated(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"sync.bin"), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/sync.bin", 0, 4, b"DATA"), 4)
        self.device.fail_sync = True
        self.assertNotEqual(self.lib.nk_sync(self.volume), 0)
        self.device.fail_sync = False

    def test_failed_device_write_never_reports_success(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"write.bin"), 0)
        self.device.fail_write = True
        payload = b"X" * 65536
        self.assertEqual(self.lib.nk_write(self.volume, b"/write.bin", 0, len(payload), payload), -1)
        self.device.fail_write = False

    def test_full_volume_reports_failure_and_preserves_successful_prefix(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"full.bin"), 0)
        payload = hashlib.shake_256(b"fill").digest(1024 * 1024)
        committed = 0
        for _ in range(128):
            count = self.lib.nk_write(self.volume, b"/full.bin", committed, len(payload), payload)
            if count < 0:
                break
            self.assertGreater(count, 0)
            committed += count
            if count < len(payload):
                break
        else:
            self.fail("64 MiB image unexpectedly accepted 128 MiB")
        self.assertGreater(committed, 0)
        self.assertEqual(self.lib.nk_sync(self.volume), 0)
        self.assertEqual(self.unmount(), 0)
        self.mount(readonly=True)
        self.assertEqual(self.read(b"/full.bin", len(payload)), payload)
        self.assertEqual(self.read(b"/full.bin", 4096, committed - 4096),
                         (payload * 2)[(committed - 4096) % len(payload):
                                       (committed - 4096) % len(payload) + 4096])

    def test_eof_during_preflight_never_starts_writing(self):
        self.device.fail_read = True
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
        self.assertEqual(self.device.writes, 0)

    def test_hibernation_refuses_write_without_modifying_image(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"hiberfil.sys"), 0)
        content = b"hibr" + bytes(4092)
        self.assertEqual(self.lib.nk_write(self.volume, b"/hiberfil.sys", 0, len(content), content), len(content))
        self.assertEqual(self.unmount(), 0)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        writes = self.device.writes
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
        self.assertEqual(self.device.writes, writes)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_dirty_volume_refuses_write_and_check_does_not_repair(self):
        subprocess.run([str(ENGINE / "ntfsprogs/ntfsfix"), str(self.path)], check=True,
                       capture_output=True, timeout=30)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 1, None, 0), -1)
        self.assertEqual(self.device.writes, 0)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_xattr_ads_roundtrip_and_delete_persist(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"attrs.bin"), 0)
        self.assertEqual(self.lib.nk_xattr_set(self.volume, b"/attrs.bin", b"com.diskferry.test", b"VALUE", 5), 0)
        data = c.create_string_buffer(16)
        self.assertEqual(self.lib.nk_xattr_get(self.volume, b"/attrs.bin", b"com.diskferry.test", data, 16), 5)
        self.assertEqual(data.raw[:5], b"VALUE")
        self.assertEqual(self.lib.nk_xattr_remove(self.volume, b"/attrs.bin", b"com.diskferry.test"), 0)
        self.assertEqual(self.lib.nk_delete(self.volume, b"/attrs.bin"), 0)
        self.assertEqual(self.unmount(), 0)
        self.mount(readonly=True)
        data = c.create_string_buffer(8)
        self.assertEqual(self.lib.nk_read(self.volume, b"/attrs.bin", 0, 8, data), -1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
