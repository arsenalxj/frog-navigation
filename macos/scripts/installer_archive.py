#!/usr/bin/env python3
"""验证青蛙导航安装回滚包；只清理明确指定的日期命名旧应用。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

BUNDLE_ID = "cn.arsenalxj.Frog"
OLD_NAME = re.compile(r"Frog\.previous-\d{8}-\d{6}\.app")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"命令失败：{' '.join(command)}\n{result.stderr.strip()}")
    return result


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def verify_app(app):
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise RuntimeError(f"不是普通应用目录，未处理：{app}")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "Frog":
        raise RuntimeError(f"应用标识未知，未处理：{app}")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    return digest(app / "Contents/MacOS/Frog")


def manifest(app):
    result = {}
    for root, directories, files in os.walk(app, followlinks=False):
        for name in sorted(directories + files):
            path = Path(root) / name
            relative = str(path.relative_to(app))
            mode = stat.S_IMODE(path.lstat().st_mode)
            if path.is_symlink():
                result[relative] = ["link", mode, os.readlink(path)]
            elif path.is_file():
                result[relative] = ["file", mode, digest(path)]
            elif path.is_dir():
                result[relative] = ["directory", mode]
            else:
                raise RuntimeError(f"应用内包含不支持的文件类型：{path}")
    return result


def archive_app(app, archive, replace=False):
    app = Path(os.path.abspath(app))
    archive = Path(os.path.abspath(archive))
    original_sha = verify_app(app)
    original_manifest = manifest(app)
    record_path = archive.with_suffix(".json")
    if (archive.suffix != ".zip" or archive.is_symlink() or record_path.is_symlink()
            or (archive.exists() and (not replace or not archive.is_file()))
            or (record_path.exists() and (not replace or not record_path.is_file()))):
        raise RuntimeError(f"归档或校验记录路径不可用，未覆盖：{archive}")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".frog-verify-", dir=archive.parent) as temporary:
        temporary = Path(temporary)
        partial = temporary / "archive.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(partial)])
        with zipfile.ZipFile(partial) as zipped:
            invalid = zipped.testzip()
            if invalid:
                raise RuntimeError(f"归档 CRC 校验失败：{invalid}")
        restored_parent = temporary / "restored"
        run(["/usr/bin/ditto", "-x", "-k", str(partial), str(restored_parent)])
        restored = restored_parent / app.name
        restored_sha = verify_app(restored)
        if restored_sha != original_sha or manifest(restored) != original_manifest:
            raise RuntimeError("解压恢复后的应用与原应用文件内容或权限不一致。")
        if manifest(app) != original_manifest:
            raise RuntimeError("归档期间原应用发生变化，未完成归档。")
        with partial.open("rb") as stream:
            os.fsync(stream.fileno())
        result = {
            "source_app": str(app), "archive": str(archive),
            "bundle_identifier": BUNDLE_ID, "binary_sha256": original_sha,
            "archive_sha256": digest(partial), "entries_verified": len(original_manifest),
            "restored_signature_valid": True, "restored_content_and_modes_match": True,
        }
        partial_record = temporary / "record.json"
        partial_record.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if replace:
            # 校验完成后在同一文件系统内原子替换固定回滚包。
            os.replace(partial, archive)
            os.replace(partial_record, record_path)
        else:
            # 一次性历史归档禁止覆盖已有版本。
            os.link(partial, archive)
            os.link(partial_record, record_path)
    return result


def running_executables():
    output = run(["/bin/ps", "-axo", "comm="]).stdout
    return {str(Path(line.strip()).resolve()) for line in output.splitlines() if line.strip().startswith("/")}


def cleanup_previous(args):
    applications = Path(args.applications_directory).resolve()
    archive_directory = Path(args.archive_directory).resolve()
    candidates = [Path(os.path.abspath(path)) for path in args.apps]
    running = running_executables()
    # 先校验全部指定路径，任何未知应用均在删除前拒绝。
    for app in candidates:
        if app.parent.resolve() != applications or not OLD_NAME.fullmatch(app.name):
            raise RuntimeError(f"不属于指定目录内的日期命名 Frog 旧版：{app}")
        verify_app(app)
        if str((app / "Contents/MacOS/Frog").resolve()) in running:
            raise RuntimeError(f"旧版仍在运行，未清理：{app}")
    records = []
    for app in candidates:
        before = manifest(app)
        archive = archive_directory / (app.stem + ".zip")
        record = archive_app(app, archive)
        record_path = archive.with_suffix(".json")
        record_path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        if manifest(app) != before:
            raise RuntimeError(f"旧版归档后发生变化，保留原应用：{app}")
        if args.unregister:
            unregister = subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True, text=True)
            record["unregister_exit_code"] = unregister.returncode
            record["unregister_output"] = (unregister.stdout + unregister.stderr).strip()
        shutil.rmtree(app)
        record["original_removed"] = not app.exists()
        record_path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        records.append(record)
    return {"removed_count": len(records), "archives": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    archive = commands.add_parser("archive", help="归档并实际解压核验一个青蛙导航应用，不删除源")
    archive.add_argument("app", type=Path)
    archive.add_argument("zip", type=Path)
    archive.add_argument("--replace", action="store_true", help="校验成功后原子替换固定回滚包")
    cleanup = commands.add_parser("cleanup-previous", help="逐个归档并清理明确指定的日期命名旧版")
    cleanup.add_argument("apps", nargs="+")
    cleanup.add_argument("--applications-directory", default="/Applications")
    cleanup.add_argument("--archive-directory", required=True)
    cleanup.add_argument("--unregister", action="store_true")
    args = parser.parse_args()
    try:
        result = archive_app(args.app, args.zip, args.replace) if args.command == "archive" else cleanup_previous(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        print(f"归档未完成：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
