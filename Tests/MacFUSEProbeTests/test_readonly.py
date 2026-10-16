"""Production macFUSE callbacks on disposable images. No mount or device access.

Set DISKFERRY_MACFUSE_PREFIX to installed/extracted macFUSE usr/local.
Headers suffice for these tests; the runtime is not loaded or simulated.
"""
import ctypes as c
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PREFIX = Path(os.environ.get("DISKFERRY_MACFUSE_PREFIX", "/usr/local"))
ENGINE = ROOT / ".build/vendor/ntfs-3g-2026.9.28"
BUILD = ROOT / ".build/macfuse-probe-tests"


def main():
    if not (PREFIX / "include/fuse/fuse.h").is_file():
        raise SystemExit("Missing macFUSE headers; set DISKFERRY_MACFUSE_PREFIX")
    BUILD.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location("ntfs_bridge_tests", ROOT / "Tests/NTFSBridgeTests/test_ntfs_bridge.py")
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    lib = bridge.build_bridge()
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    sanitizer_flags = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if os.environ.get("DISKFERRY_PROBE_SANITIZERS") == "1" else []
    subprocess.run([
        "xcrun", "clang", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-D_FILE_OFFSET_BITS=64",
        *sanitizer_flags,
        "-I", str(PREFIX / "include/fuse"), "-I", str(ROOT / "Tools/DiskFerryMacFUSE"),
        "-I", str(ROOT / "Extensions/DiskFerryNTFS/bridge"),
        str(ROOT / "Tools/DiskFerryMacFUSE/readonly.c"),
        str(ROOT / "Tests/MacFUSEProbeTests/readonly_tests.c"),
        str(bridge.BUILD / "bridge.dylib"), "-pthread", "-o", str(BUILD / "readonly-tests"),
    ], check=True, env=env, timeout=120)
    with tempfile.TemporaryDirectory(prefix="readonly-", dir=BUILD) as temporary:
        image = Path(temporary) / "disposable.ntfs"
        with image.open("wb") as f:
            f.truncate(64 * 1024 * 1024)
        subprocess.run([str(ENGINE / "ntfsprogs/mkntfs"), "-F", "-Q", str(image)],
                       check=True, capture_output=True, timeout=60)
        device = bridge.ImageIO(image)
        volume = None
        try:
            error = c.create_string_buffer(1024)
            volume = lib.nk_mount_io(c.byref(device.io), error, len(error))
            assert volume, error.value
            assert lib.nk_create(volume, b"/", b"Mixed.txt") == 0
            content = bytes(i % 251 for i in range(100001))
            assert lib.nk_write(volume, b"/Mixed.txt", 0, len(content), c.create_string_buffer(content)) == len(content)
            times = bridge.Times(2 | 4,  # NK_TIME_MODIFY | NK_TIME_BIRTH
                                 bridge.Timestamp(), bridge.Timestamp(-1, 123456789), bridge.Timestamp(1500000000, 987654321))
            assert lib.nk_set_times_precise(volume, b"/Mixed.txt", c.byref(times)) == 0
            assert lib.nk_xattr_set(volume, b"/Mixed.txt", b"user.test", c.create_string_buffer(b"value"), 5) == 0
            for directory, value in [("Caf\u00e9", b"NFC"), ("Cafe\u0301", b"NFD")]:
                encoded = directory.encode()
                assert lib.nk_mkdir(volume, b"/", encoded) == 0
                parent = b"/" + encoded
                assert lib.nk_create(volume, parent, b"child") == 0
                assert lib.nk_write(volume, parent + b"/child", 0, 3, c.create_string_buffer(value)) == 3
            assert lib.nk_create_symlink(volume, b"/", b"shortcut", b"Mixed.txt") == 0
            rc = lib.nk_umount(volume)
            volume = None
            assert rc == 0
        finally:
            if volume:
                lib.nk_umount(volume)
            device.close()
        alias = Path(temporary) / "symlink.ntfs"
        alias.symlink_to(image.name)
        before = hashlib.sha256(image.read_bytes()).hexdigest()
        subprocess.run([str(BUILD / "readonly-tests"), str(image), str(alias)], check=True, timeout=60)
        assert hashlib.sha256(image.read_bytes()).hexdigest() == before
        print("PASS entire image SHA-256 unchanged after callback tests")


if __name__ == "__main__":
    main()
