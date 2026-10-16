"""Real NTFS image tests for the callback bridge; no devices or FSKit mount.

Run with Python 3 after Scripts/prepare-ntfs-core.sh. Only freshly created
regular files inside .build are opened. No raw-device test argument exists.
"""
import ctypes as c
import errno
import hashlib
import os
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
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


class FileStat(c.Structure):
    _fields_ = [("is_dir", c.c_int), ("size", c.c_longlong), ("alloc_size", c.c_longlong),
                ("inode", c.c_uint64), ("atime", c.c_longlong), ("mtime", c.c_longlong),
                ("ctime", c.c_longlong), ("btime", c.c_longlong), ("is_symlink", c.c_int),
                ("koio_ok", c.c_int), ("is_resident", c.c_int), ("atime_nsec", c.c_int),
                ("mtime_nsec", c.c_int), ("ctime_nsec", c.c_int), ("btime_nsec", c.c_int)]


class Timestamp(c.Structure):
    _fields_ = [("seconds", c.c_longlong), ("nanoseconds", c.c_int)]


class Times(c.Structure):
    _fields_ = [("valid", c.c_uint), ("access", Timestamp), ("modify", Timestamp), ("birth", Timestamp)]


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
    return load_bridge()


def load_bridge():
    lib = c.CDLL(str(BUILD / "bridge.dylib"), use_errno=True)
    signatures = {
        "nk_mount_io": (c.c_void_p, [c.POINTER(IO), c.c_char_p, c.c_size_t]),
        "nk_umount": (c.c_int, [c.c_void_p]),
        "nk_stat_path": (c.c_int, [c.c_void_p, c.c_char_p, c.POINTER(FileStat)]),
        "nk_lookup_child": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_void_p, c.c_size_t, c.POINTER(FileStat)]),
        "nk_create": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "nk_mkdir": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "nk_create_symlink": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p]),
        "nk_delete": (c.c_int, [c.c_void_p, c.c_char_p]),
        "nk_rename": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p]),
        "nk_truncate": (c.c_int, [c.c_void_p, c.c_char_p, c.c_longlong]),
        "nk_read": (c.c_longlong, [c.c_void_p, c.c_char_p, c.c_longlong, c.c_longlong, c.c_void_p]),
        "nk_readlink": (c.c_int, [c.c_void_p, c.c_char_p, c.c_void_p, c.c_size_t]),
        "nk_write": (c.c_longlong, [c.c_void_p, c.c_char_p, c.c_longlong, c.c_longlong, c.c_void_p]),
        "nk_sync": (c.c_int, [c.c_void_p]),
        "nk_is_dirty": (c.c_int, [c.c_void_p]),
        "nk_fsck": (c.c_int, [c.POINTER(IO), c.c_int, c.c_char_p, c.c_size_t]),
        "nk_xattr_set": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_void_p, c.c_longlong]),
        "nk_xattr_get": (c.c_longlong, [c.c_void_p, c.c_char_p, c.c_char_p, c.c_void_p, c.c_longlong]),
        "nk_xattr_remove": (c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        "nk_set_label": (c.c_int, [c.c_void_p, c.c_char_p]),
        "nk_set_times": (c.c_int, [c.c_void_p, c.c_char_p, c.c_longlong, c.c_longlong, c.c_longlong]),
        "nk_set_times_precise": (c.c_int, [c.c_void_p, c.c_char_p, c.POINTER(Times)]),
    }
    for name, (result, arguments) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result, arguments
    return lib


def raw_filetimes(image, filename):
    """Read STANDARD_INFORMATION bytes with the independent stock utility.

    Do not use the bridge's timestamp decoder as the only write oracle.
    """
    if not stat.S_ISREG(Path(image).lstat().st_mode):
        raise ValueError("Only ordinary test images are allowed")
    raw = subprocess.check_output([str(ENGINE / "ntfsprogs/ntfscat"), "-a", "0x10", str(image), filename],
                                  stderr=subprocess.PIPE, timeout=30)
    if len(raw) < 32:
        raise AssertionError("Truncated STANDARD_INFORMATION attribute")
    return dict(zip(("birth", "modify", "change", "access"), struct.unpack("<4Q", raw[:32])))


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

    def test_precise_times_preserve_pre_epoch_fractions_and_persist(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"precise"), 0)
        requested = Times(7, Timestamp(-1, 123456789), Timestamp(-123456789, 987654321), Timestamp(-11644473600, 0))
        before = time.time_ns()
        self.assertEqual(self.lib.nk_set_times_precise(self.volume, b"/precise", c.byref(requested)), 0)
        updated = FileStat()
        self.assertEqual(self.lib.nk_stat_path(self.volume, b"/precise", c.byref(updated)), 0)
        self.assertGreaterEqual(updated.ctime * 10**9 + updated.ctime_nsec, before - 99)
        self.assertLessEqual(updated.ctime * 10**9 + updated.ctime_nsec, time.time_ns())
        self.assertEqual(self.unmount(), 0)
        before_hash = hashlib.sha256(self.path.read_bytes()).hexdigest()
        raw = raw_filetimes(self.path, "/precise")
        self.assertEqual(raw["birth"], 0)
        self.assertEqual(raw["modify"], (-123456789 + 11644473600) * 10**7 + 9876543)
        self.assertEqual(raw["access"], (-1 + 11644473600) * 10**7 + 1234567)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before_hash)
        self.mount(readonly=True)
        self.assertEqual(self.lib.nk_stat_path(self.volume, b"/precise", c.byref(updated)), 0)
        self.assertEqual((updated.atime, updated.atime_nsec), (-1, 123456700))
        self.assertEqual((updated.mtime, updated.mtime_nsec), (-123456789, 987654300))
        self.assertEqual((updated.btime, updated.btime_nsec), (-11644473600, 0))

    def test_invalid_precise_times_leave_all_attributes_and_image_unchanged(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        self.assertEqual(self.lib.nk_sync(self.volume), 0)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        writes = self.device.writes
        for seconds, nanos in [(-11644473601, 0), (2**63 - 1, 0), (0, -1), (0, 10**9),
                               (910692730085, 477580800), (910692730086, 0)]:
            requested = Times(3, Timestamp(1, 1), Timestamp(seconds, nanos), Timestamp())
            with self.subTest(seconds=seconds, nanos=nanos):
                self.assertEqual(self.lib.nk_set_times_precise(self.volume, b"/original", c.byref(requested)), -1)
                self.assertEqual(c.get_errno(), errno.EINVAL)
        for requested in [None, c.byref(Times(8, Timestamp(), Timestamp(), Timestamp()))]:
            self.assertEqual(self.lib.nk_set_times_precise(self.volume, b"/original", requested), -1)
            self.assertEqual(c.get_errno(), errno.EINVAL)
        # Unrequested fields must not be converted, overflow, or dirty the inode.
        ignored = Times(0, Timestamp(2**63 - 1, -1), Timestamp(-2**63, -1), Timestamp(0, 10**9))
        self.assertEqual(self.lib.nk_set_times_precise(self.volume, b"/original", c.byref(ignored)), 0)
        self.assertEqual(self.lib.nk_set_times(self.volume, b"/original", 2**63 - 1, -1, -1), -1)
        self.assertEqual(c.get_errno(), errno.EINVAL)
        self.assertEqual(self.device.writes, writes)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_precise_times_refuse_readonly_without_writes(self):
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.mount(readonly=True)
        requested = Times(7, Timestamp(1, 123), Timestamp(2, 456), Timestamp(3, 789))
        self.assertEqual(self.lib.nk_set_times_precise(self.volume, b"/", c.byref(requested)), -1)
        self.assertEqual(c.get_errno(), errno.EROFS)
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.device.writes, 0)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_long_name_lookup_and_case_collision_protection(self):
        self.mount()
        stored = "R\u00e9sum\u00e9.TXT".encode()
        variant = "R\u00c9SUM\u00c9.txt".encode()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", stored), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/" + stored, 0, 4, b"KEEP"), 4)
        actual, attributes = c.create_string_buffer(1024), FileStat()
        self.assertEqual(self.lib.nk_lookup_child(self.volume, b"/", variant, actual, len(actual), c.byref(attributes)), 0)
        self.assertEqual(actual.value, stored)
        self.assertEqual(attributes.size, 4)
        for operation in [lambda: self.lib.nk_create(self.volume, b"/", variant),
                          lambda: self.lib.nk_mkdir(self.volume, b"/", variant),
                          lambda: self.lib.nk_create_symlink(self.volume, b"/", variant, b"target")]:
            self.assertEqual(operation(), -1)
            self.assertEqual(c.get_errno(), errno.EEXIST)
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"other"), 0)
        self.assertEqual(self.lib.nk_rename(self.volume, b"/other", b"/", variant), -1)
        self.assertEqual(c.get_errno(), errno.EEXIST)
        self.assertEqual(self.lib.nk_rename(self.volume, b"/" + stored, b"/", variant), 0)
        self.assertEqual(self.unmount(), 0)
        self.mount(readonly=True)
        self.assertEqual(self.read(b"/" + variant, 16), b"KEEP")
        self.assertEqual(self.lib.nk_lookup_child(self.volume, b"/", stored, actual, len(actual), c.byref(attributes)), 0)
        self.assertEqual(actual.value, variant)
        small = c.create_string_buffer(b"UNCHANGED")
        before = small.raw
        self.assertEqual(self.lib.nk_lookup_child(self.volume, b"/", stored, small, 2, c.byref(attributes)), -1)
        self.assertEqual(c.get_errno(), errno.ERANGE)
        self.assertEqual(small.raw, before)
        self.assertEqual(self.lib.nk_lookup_child(self.volume, b"/", b"$mft", actual, len(actual), c.byref(attributes)), -1)
        self.assertEqual(c.get_errno(), errno.EPERM)

    def test_imported_case_variants_require_exact_or_unique_lookup(self):
        source = Path(self.temporary.name) / "import.txt"
        for name, value in [("Alpha", b"FIRST"), ("ALPHA", b"SECOND")]:
            source.write_bytes(value)
            subprocess.run([str(ENGINE / "ntfsprogs/ntfscp"), "-f", str(self.path), str(source), "/" + name],
                           check=True, capture_output=True, timeout=30)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.mount(readonly=True)
        actual, attributes = c.create_string_buffer(1024), FileStat()
        for name, value in [(b"Alpha", b"FIRST"), (b"ALPHA", b"SECOND")]:
            self.assertEqual(self.lib.nk_lookup_child(self.volume, b"/", name, actual, len(actual), c.byref(attributes)), 0)
            self.assertEqual(actual.value, name)
            self.assertEqual(self.read(b"/" + name, 32), value)
        self.assertEqual(self.lib.nk_lookup_child(self.volume, b"/", b"alpha", actual, len(actual), c.byref(attributes)), -1)
        self.assertEqual(c.get_errno(), errno.EIO)
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.device.writes, 0)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

    def test_component_validation_refuses_escape_without_mutation(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        self.assertEqual(self.lib.nk_sync(self.volume), 0)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        writes = self.device.writes
        for name in [b"", b".", b"..", b"nested/escaped", b"a" * 256]:
            expected = errno.ENAMETOOLONG if len(name) == 256 else errno.EINVAL
            for operation in [lambda: self.lib.nk_create(self.volume, b"/", name),
                              lambda: self.lib.nk_mkdir(self.volume, b"/", name),
                              lambda: self.lib.nk_create_symlink(self.volume, b"/", name, b"target"),
                              lambda: self.lib.nk_rename(self.volume, b"/original", b"/", name)]:
                with self.subTest(name=name, operation=operation):
                    self.assertEqual(operation(), -1)
                    self.assertEqual(c.get_errno(), expected)
        self.assertEqual(self.device.writes, writes)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

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

    def test_metadata_files_refuse_all_public_mutations_without_writes(self):
        self.mount()
        before = self.path.read_bytes()
        writes = self.device.writes
        for path in [b"/$MFT", b"/$LogFile", b"//$LogFile", b"/$Bitmap", b"/$Boot",
                     b"/$Extend/$Quota", b"/$Extend/$ObjId", b"/$Extend/$Reparse"]:
            operations = [
                ("times", lambda: self.lib.nk_set_times(self.volume, path, 1, 1, 1)),
                ("write", lambda: self.lib.nk_write(self.volume, path, 0, 3, b"BAD")),
                ("truncate", lambda: self.lib.nk_truncate(self.volume, path, 0)),
                ("xattr-set", lambda: self.lib.nk_xattr_set(self.volume, path, b"test", b"BAD", 3)),
                ("xattr-remove", lambda: self.lib.nk_xattr_remove(self.volume, path, b"test")),
                ("rename", lambda: self.lib.nk_rename(self.volume, path, b"/", b"renamed")),
                ("delete", lambda: self.lib.nk_delete(self.volume, path)),
            ]
            for operation, call in operations:
                with self.subTest(path=path, operation=operation):
                    c.set_errno(0)
                    self.assertEqual(call(), -1)
                    self.assertEqual(c.get_errno(), errno.EPERM)
                    self.assertEqual(self.device.writes, writes)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 0)

    def test_metadata_directories_refuse_namespace_changes(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        before = self.path.read_bytes()
        writes = self.device.writes
        operations = [
            lambda: self.lib.nk_create(self.volume, b"/$Extend", b"file"),
            lambda: self.lib.nk_mkdir(self.volume, b"/$Extend", b"directory"),
            lambda: self.lib.nk_create_symlink(self.volume, b"/$Extend", b"link", b"/original"),
            lambda: self.lib.nk_rename(self.volume, b"/original", b"/$Extend", b"moved"),
            lambda: self.lib.nk_rename(self.volume, b"/$Extend", b"/", b"moved"),
            lambda: self.lib.nk_delete(self.volume, b"/$Extend"),
            lambda: self.lib.nk_rename(self.volume, b"/", b"/", b"moved"),
        ]
        for index, operation in enumerate(operations):
            with self.subTest(operation=index):
                c.set_errno(0)
                self.assertEqual(operation(), -1)
                self.assertEqual(c.get_errno(), errno.EPERM)
                self.assertEqual(self.device.writes, writes)
        self.assertEqual(self.path.read_bytes(), before)

    def test_hidden_metadata_cannot_be_read_by_direct_path(self):
        before = self.path.read_bytes()
        self.mount(readonly=True)
        for path in [b"/$MFT", b"/$LogFile", b"/$Extend/$Quota", b"//$Extend/$ObjId"]:
            with self.subTest(path=path):
                data = c.create_string_buffer(512)
                c.set_errno(0)
                self.assertEqual(self.lib.nk_read(self.volume, path, 0, len(data), data), -1)
                self.assertEqual(c.get_errno(), errno.EPERM)
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.device.writes, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_dollar_prefixed_user_files_and_root_attributes_remain_usable(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"$user-data"), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/$user-data", 0, 4, b"KEEP"), 4)
        self.assertEqual(self.lib.nk_xattr_set(self.volume, b"/", b"test", b"ROOT", 4), 0)
        self.assertEqual(self.lib.nk_set_times(self.volume, b"/", 1, 1, 1), 0)
        self.assertEqual(self.unmount(), 0)
        self.mount(readonly=True)
        self.assertEqual(self.read(b"/$user-data", 16), b"KEEP")
        data = c.create_string_buffer(4)
        self.assertEqual(self.lib.nk_xattr_get(self.volume, b"/", b"test", data, 4), 4)
        self.assertEqual(data.raw, b"ROOT")

    def test_system_flagged_user_symlinks_are_not_mistaken_for_metadata(self):
        self.mount()
        # The pinned engine creates Interix links with FILE_ATTR_SYSTEM.
        self.assertEqual(self.lib.nk_create_symlink(self.volume, b"/", b"link", b"/target"), 0)
        self.assertEqual(self.lib.nk_rename(self.volume, b"/link", b"/", b"renamed-link"), 0)
        self.assertEqual(self.unmount(), 0)
        self.mount()
        data = c.create_string_buffer(256)
        self.assertEqual(self.lib.nk_readlink(self.volume, b"/renamed-link", data, len(data)), 0)
        self.assertEqual(data.value, b"/target")
        self.assertEqual(self.lib.nk_delete(self.volume, b"/renamed-link"), 0)

    def test_normal_close_cleans_only_after_persisting_and_allows_next_session(self):
        self.mount()
        self.assertEqual(self.lib.nk_is_dirty(self.volume), 1)
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"persisted"), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/persisted", 0, 4, b"KEEP"), 4)
        self.assertEqual(self.lib.nk_sync(self.volume), 0)
        self.assertEqual(self.lib.nk_is_dirty(self.volume), 1)
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 0)
        self.mount()
        self.assertEqual(self.read(b"/persisted", 16), b"KEEP")
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 0)

    def test_cannot_open_writer_if_session_marker_cannot_be_synced(self):
        self.device.fail_sync = True
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
        self.assertGreater(self.device.syncs, 0)
        self.device.fail_sync = False
        # A marker whose persistence could not be confirmed is not erased.
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)

    def test_recovered_sync_callback_cannot_clean_a_failed_session(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        self.assertEqual(self.lib.nk_write(self.volume, b"/original", 0, 4, b"KEEP"), 4)
        self.device.fail_sync = True
        self.assertEqual(self.lib.nk_sync(self.volume), -1)
        self.device.fail_sync = False
        attempts = self.device.writes
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"after-error"), -1)
        self.assertEqual(self.lib.nk_sync(self.volume), -1)
        self.assertEqual(self.unmount(), -1)
        self.assertEqual(self.device.writes, attempts)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)
        self.mount(readonly=True)
        self.assertEqual(self.read(b"/original", 16), b"KEEP")

    def test_shutdown_sync_failure_keeps_the_dirty_marker(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        self.device.fail_sync = True
        self.assertEqual(self.unmount(), -1)
        self.device.fail_sync = False
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)

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

    def test_mutating_operations_do_not_hide_a_device_write_failure(self):
        operations = [
            ("create", lambda: self.lib.nk_create(self.volume, b"/", b"new-file")),
            ("mkdir", lambda: self.lib.nk_mkdir(self.volume, b"/", b"new-directory")),
            ("rename", lambda: self.lib.nk_rename(self.volume, b"/original", b"/", b"renamed")),
            ("delete", lambda: self.lib.nk_delete(self.volume, b"/original")),
            ("truncate", lambda: self.lib.nk_truncate(self.volume, b"/original", 0)),
            ("times", lambda: self.lib.nk_set_times(self.volume, b"/original", 1, 1, 1)),
            ("label", lambda: self.lib.nk_set_label(self.volume, b"CHANGED")),
            ("xattr set", lambda: self.lib.nk_xattr_set(self.volume, b"/original", b"test", b"NEW", 3)),
            ("xattr remove", lambda: self.lib.nk_xattr_remove(self.volume, b"/original", b"test")),
        ]
        for index, (name, operation) in enumerate(operations):
            with self.subTest(operation=name):
                if index:
                    self.device.close()
                    shutil.copyfile(self.template, self.path)
                    self.device = ImageIO(self.path)
                self.mount()
                self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
                self.assertEqual(self.lib.nk_write(self.volume, b"/original", 0, 4, b"KEEP"), 4)
                self.assertEqual(self.lib.nk_xattr_set(self.volume, b"/original", b"test", b"OLD", 3), 0)
                attempts = self.device.writes
                self.device.fail_write = True
                try:
                    c.set_errno(0)
                    result = operation()
                    self.assertGreater(self.device.writes, attempts, "fixture must reach a device write")
                    self.assertEqual(result, -1)
                    self.assertEqual(c.get_errno(), errno.EIO, "cleanup must preserve the device error")
                finally:
                    self.device.fail_write = False
                    self.assertEqual(self.unmount(), -1)

    def test_io_failure_freezes_further_mutation_and_cannot_be_forgotten(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        self.device.fail_write = True
        self.assertEqual(self.lib.nk_write(self.volume, b"/original", 0, 65536, b"X" * 65536), -1)
        self.device.fail_write = False
        attempts = self.device.writes
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"after-error"), -1)
        self.assertEqual(self.lib.nk_truncate(self.volume, b"/original", 0), -1)
        self.assertEqual(self.lib.nk_write(self.volume, b"/original", 0, 4, b"BAD!"), -1)
        self.assertEqual(self.device.writes, attempts)
        self.assertEqual(self.lib.nk_sync(self.volume), -1)
        self.assertEqual(self.unmount(), -1)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)

    def test_read_failure_also_prevents_further_writes(self):
        self.mount()
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"original"), 0)
        data = b"X" * (2 * 1024 * 1024)
        self.assertEqual(self.lib.nk_write(self.volume, b"/original", 0, len(data), data), len(data))
        self.device.fail_read = True
        output = c.create_string_buffer(4096)
        self.assertEqual(self.lib.nk_read(self.volume, b"/original", 1024 * 1024, 4096, output), -1)
        self.device.fail_read = False
        attempts = self.device.writes
        self.assertEqual(self.lib.nk_create(self.volume, b"/", b"after-error"), -1)
        self.assertEqual(self.lib.nk_sync(self.volume), -1)
        self.assertEqual(self.unmount(), -1)
        self.assertEqual(self.device.writes, attempts)
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)

    def test_killed_writer_leaves_a_dirty_volume_and_readonly_data(self):
        # The child opens only the fresh regular image created by this test.
        # SIGKILL models process loss; it does not model hardware power loss.
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                  "--interrupted-writer", str(self.path)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([child.stdout], [], [], 20)
            self.assertTrue(ready, "writer did not report persisted data")
            self.assertEqual(child.stdout.readline(), b"ready\n")
            child.kill()
            child.wait(timeout=10)
            self.assertEqual(child.returncode, -signal.SIGKILL)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            child.stdout.close()
            child.stderr.close()
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), 1)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
        self.assertEqual(self.device.writes, 0)
        self.mount(readonly=True)
        self.assertEqual(self.read(b"/survives.bin", 32), b"persisted before interruption")
        self.assertEqual(self.unmount(), 0)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)

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

    def test_invalid_windows_journal_refuses_before_writing_a_session_marker(self):
        # Build an invalid $LogFile only inside this fresh ordinary image.
        # ntfscp is the pinned upstream fixture tool, never given a device.
        invalid = Path(self.temporary.name) / "invalid-logfile.bin"
        invalid.write_bytes(bytes(4096))
        subprocess.run([str(ENGINE / "ntfsprogs/ntfscp"), "--inode", str(self.path),
                        str(invalid), "2"], check=True, capture_output=True, timeout=30)
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.assertEqual(self.lib.nk_fsck(c.byref(self.device.io), 0, None, 0), -1)
        self.assertFalse(self.lib.nk_mount_io(c.byref(self.device.io), None, 0))
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


def interrupted_writer(path):
    # Refuse arbitrary caller-supplied devices or files outside test fixtures.
    path = Path(path).resolve(strict=True)
    if not path.is_relative_to(BUILD.resolve()) or path.name != "disposable.ntfs":
        raise ValueError("Expected a fresh bridge-test image")
    device = ImageIO(path)
    lib = load_bridge()
    volume = lib.nk_mount_io(c.byref(device.io), None, 0)
    if not volume or lib.nk_create(volume, b"/", b"survives.bin") != 0:
        raise RuntimeError("writer could not initialize fixture")
    data = b"persisted before interruption"
    if lib.nk_write(volume, b"/survives.bin", 0, len(data), data) != len(data) or lib.nk_sync(volume) != 0:
        raise RuntimeError("writer could not persist fixture")
    print("ready", flush=True)
    # Wait on our parent; do not voluntarily close/clean the NTFS session.
    signal.pause()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--interrupted-writer":
        interrupted_writer(sys.argv[2])
    else:
        unittest.main(verbosity=2)
