#!/usr/bin/env python3
"""Verify NTFS core on a new ordinary file image. No raw device argument exists."""
import argparse
import hashlib
import json
import platform
import stat
import subprocess
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / "artifacts/ntfs-validation")
    args = parser.parse_args()
    tools = root / ".build/vendor/ntfs-3g-2026.9.28/ntfsprogs"
    for name in ("mkntfs", "ntfscp", "ntfscat"):
        if not (tools / name).is_file():
            raise SystemExit("先执行 bash Scripts/prepare-ntfs-core.sh。")
    args.output.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="ntfs-", dir=args.output.resolve()))
    image = run / "disposable.ntfs"
    with image.open("xb") as stream:
        stream.truncate(64 * 1024 * 1024)
    assert stat.S_ISREG(image.stat().st_mode) and image.parent == run

    def execute(name, *arguments):
        result = subprocess.run([str(tools / name), *map(str, arguments)],
                                capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(f"{name} failed: {result.stderr.decode(errors='replace')}")
        return result

    formatted = execute("mkntfs", "-F", "-Q", "-L", "DISKFERRY_TEST", image)
    (run / "format.log").write_bytes(formatted.stdout + formatted.stderr)
    payloads = [
        ("create-unicode", bytes(range(256)) * 8192 + "盘渡 NTFS 内容校验\n".encode()),
        ("overwrite-shorter", "覆盖后长度更短；跨平台内容校验。\n".encode() * 256),
        ("truncate-empty", b""),
    ]
    checks = []
    for label, content in payloads:
        source = run / f"{label}.bin"
        source.write_bytes(content)
        execute("ntfscp", image, source, "/盘渡验证-旅行档案.bin")
        readback = execute("ntfscat", image, "/盘渡验证-旅行档案.bin").stdout
        (run / f"{label}-readback.bin").write_bytes(readback)
        check = dict(case=label, bytes=len(content),
                     sourceSHA256=hashlib.sha256(content).hexdigest(),
                     readbackSHA256=hashlib.sha256(readback).hexdigest(), passed=content == readback)
        checks.append(check)
        if not check["passed"]:
            raise RuntimeError(f"内容校验失败：{label}")
    cli = root / "dist/diskferry"
    if cli.is_file():
        with (run / "probe.json").open("wb") as stream:
            subprocess.run([str(cli), "probe-image", str(image)], stdout=stream, check=True, timeout=20)
    report = dict(backend="NTFS-3G", version="2026.9.28", architecture=platform.machine(),
                  imageBytes=image.stat().st_size, imageOnly=True, fsKitMountTested=False,
                  finderMountTested=False, checks=checks)
    (run / "roundtrip.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(run / "roundtrip.json")


if __name__ == "__main__":
    main()
