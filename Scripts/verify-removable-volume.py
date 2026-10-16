#!/usr/bin/env python3
"""Exercise a mounted, explicitly identified physical USB volume in a new test directory.

No formatting, raw-device access or forced unmount. Reports distinguish system
filesystem operations from DiskFerry-provided NTFS writes. Re-run `verify` after
a normal unmount/mount to check persistence. All payload paths are report-relative.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent


def execute(arguments):
    return subprocess.check_output(list(map(str, arguments)), timeout=30)


def info(device):
    if not re.fullmatch(r"disk[0-9]+(?:s[0-9]+)*", device):
        raise ValueError("Expected a BSD disk identifier, not a path")
    return plistlib.loads(execute(["/usr/sbin/diskutil", "info", "-plist", device]))


def inspect(device, expected_uuid, require_write=False):
    volume = info(device)
    whole = info(volume["ParentWholeDisk"])
    if not (volume.get("Internal") is False and whole.get("Internal") is False
            and whole.get("WholeDisk") is True and whole.get("VirtualOrPhysical") == "Physical"
            and whole.get("BusProtocol") == "USB"
            and (not require_write or volume.get("WritableVolume") is True)
            and volume.get("VolumeUUID") == expected_uuid):
        raise ValueError("Volume is not the approved, mounted, writable physical USB volume")
    cli = ROOT / "dist/diskferry"
    if not cli.is_file():
        raise ValueError("Build the app and CLI with Scripts/build-app.sh first")
    snapshot = json.loads(execute([cli, "scan"]))["snapshot"]
    entry = next(v for v in snapshot["volumes"] if v["id"] == device)
    if not entry.get("liveIdentity") or entry["volumeUUID"] != expected_uuid:
        raise ValueError("DiskFerry could not confirm the live connection identity")
    mount = Path(volume["MountPoint"])
    if not mount.is_absolute() or not os.path.ismount(mount) or mount.is_symlink():
        raise ValueError("Not a mounted volume root")
    identity = {key: entry[key] for key in
                ("id", "wholeDiskID", "volumeUUID", "liveIdentity", "mountPoint", "fileSystem")}
    identity.update(wholeBytes=whole["TotalSize"], media=whole["IORegistryEntryName"])
    return identity, mount


def recheck(expected):
    current, _ = inspect(expected["id"], expected["volumeUUID"])
    if current != expected:
        raise ValueError("USB connection or mount identity changed; test stopped")


def relative_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(p in ("..", ".") for p in path.parts):
        raise ValueError("Invalid relative test payload path")
    return path


def open_directory(parent, name):
    # Retaining directory descriptors prevents a vanished mount path from being
    # recreated on the host filesystem. Never follow a symlink supplied by a disk.
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)


def parent_fd(directory, relative, create=False):
    path = relative_path(relative)
    current = os.dup(directory)
    try:
        for part in path.parts[:-1]:
            if create:
                try:
                    os.mkdir(part, dir_fd=current)
                except FileExistsError:
                    pass
            child = open_directory(current, part)
            os.close(current)
            current = child
        return current, path.name
    except BaseException:
        os.close(current)
        raise


def put(directory, name, chunks):
    parent, leaf = parent_fd(directory, name, create=True)
    try:
        descriptor = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=parent)
        with os.fdopen(descriptor, "wb") as stream:
            for chunk in chunks:
                stream.write(chunk)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(parent)


def digest(directory, name):
    parent, leaf = parent_fd(directory, name)
    try:
        descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("Payload is not a regular file")
            size = os.fstat(stream.fileno()).st_size
            return {"path": name, "bytes": size, "sha256": hashlib.file_digest(stream, "sha256").hexdigest()}
    finally:
        os.close(parent)


def write_cases(directory, mib):
    expected = {}

    def write(name, chunks):
        hasher, count = hashlib.sha256(), 0

        def checked_chunks():
            nonlocal count
            for chunk in chunks:
                hasher.update(chunk)
                count += len(chunk)
                yield chunk
        put(directory, name, checked_chunks())
        expected[name] = {"path": name, "bytes": count, "sha256": hasher.hexdigest()}

    write("中文 空格_é_😀.bin", [bytes(range(256)) * 128 + "盘渡数据校验\n".encode()])
    write("large-file.bin", (hashlib.shake_256(f"diskferry-{i}".encode()).digest(1024 * 1024)
                             for i in range(mib)))
    for i in range(64):
        write(f"small-files/文件-{i:03}.txt", [f"DiskFerry file {i}\n".encode() * (i + 1)])
    write("/".join([f"目录-{i}" for i in range(8)]) + "/leaf.txt", [b"nested payload\n"])
    write("empty-file", [])
    write("atomic-target.txt", [b"old"])
    write("atomic-temp.txt", [b"new atomic content\n"])
    os.replace("atomic-temp.txt", "atomic-target.txt", src_dir_fd=directory, dst_dir_fd=directory)
    expected["atomic-target.txt"] = dict(expected.pop("atomic-temp.txt"), path="atomic-target.txt")
    write("before-rename.txt", ["rename-中文\n".encode()])
    os.rename("before-rename.txt", "after-rename.txt", src_dir_fd=directory, dst_dir_fd=directory)
    expected["after-rename.txt"] = dict(expected.pop("before-rename.txt"), path="after-rename.txt")
    payload = bytearray(bytes(range(256)) * 4096)
    write("random-write.bin", [payload])
    descriptor = os.open("random-write.bin", os.O_RDWR | os.O_NOFOLLOW, dir_fd=directory)
    try:
        for offset, replacement in [(0, b"START"), (777, b"middle"), (65533, b"cross-boundary")]:
            if os.pwrite(descriptor, replacement, offset) != len(replacement):
                raise OSError("Short random write")
            payload[offset:offset + len(replacement)] = replacement
        os.ftruncate(descriptor, 70001)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    expected["random-write.bin"] = dict(path="random-write.bin", bytes=70001,
                                        sha256=hashlib.sha256(payload[:70001]).hexdigest())
    write("deleted-file.txt", [b"remove this file"])
    os.unlink("deleted-file.txt", dir_fd=directory)
    del expected["deleted-file.txt"]
    return list(expected.values()), ["deleted-file.txt", "before-rename.txt", "atomic-temp.txt"]


def check(directory, expected, absent):
    for record in expected:
        if digest(directory, record["path"]) != record:
            raise ValueError(f"Content mismatch: {record['path']}")
    for name in absent:
        parent, leaf = parent_fd(directory, name)
        try:
            os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            continue
        finally:
            os.close(parent)
        raise ValueError(f"Deleted or renamed file still exists: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    write = sub.add_parser("write")
    write.add_argument("--device", required=True)
    write.add_argument("--expect-volume-uuid", required=True)
    write.add_argument("--mib", type=int, default=128, choices=range(1, 4096), metavar="1..4095")
    write.add_argument("--report", type=Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "write":
        identity, mount = inspect(args.device, args.expect_volume_uuid, require_write=True)
        if os.statvfs(mount).f_bavail * os.statvfs(mount).f_frsize < (args.mib + 64) * 1024 * 1024:
            raise ValueError("Insufficient free space for test")
        if args.report.exists() or args.report.resolve().is_relative_to(mount):
            raise ValueError("Report must be new and outside the test volume")
        name = f"DiskFerry-Verification-{uuid.uuid4()}"
        report = dict(schemaVersion=1, createdAt=datetime.now(timezone.utc).isoformat(),
                      identity=identity, directory=name, passed=False,
                      filesystemProvider="system mount; not proof of DiskFerry NTFS writing")
    else:
        report = json.loads(args.report.read_text())
        identity, mount = inspect(report["identity"]["id"], report["identity"]["volumeUUID"])
        if identity != report["identity"]:
            raise ValueError("Original device connection changed; requalify explicitly")
        name = report["directory"]
        if not re.fullmatch(r"DiskFerry-Verification-[0-9a-f-]{36}", name):
            raise ValueError("Invalid verification directory")
    root = os.open(mount, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    directory = None
    started = time.monotonic()
    try:
        recheck(identity)
        if os.fstat(root).st_dev != os.stat("/dev/" + identity["id"]).st_rdev:
            raise ValueError("Open directory does not belong to the approved device")
        if args.command == "write":
            os.mkdir(name, mode=0o700, dir_fd=root)
        directory = open_directory(root, name)
        if os.fstat(directory).st_dev != os.fstat(root).st_dev:
            raise ValueError("Verification directory changed filesystem")
        if args.command == "write":
            report["files"], report["absent"] = write_cases(directory, args.mib)
        check(directory, report["files"], report["absent"])
        recheck(identity)
        report["passed"] = True
        report.pop("error", None)
        report.setdefault("checks", []).append(dict(operation=args.command, passed=True,
            checkedAt=datetime.now(timezone.utc).isoformat(), seconds=round(time.monotonic() - started, 3)))
    except BaseException as error:
        report["passed"] = False
        report["error"] = str(error)
        raise
    finally:
        if directory is not None:
            os.close(directory)
        os.close(root)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(passed=True, files=len(report["files"]), report=str(args.report),
                          filesystem=identity["fileSystem"], seconds=report["checks"][-1]["seconds"])))


if __name__ == "__main__":
    main()
