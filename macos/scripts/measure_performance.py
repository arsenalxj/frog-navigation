#!/usr/bin/env python3
"""青蛙导航 Release 独立验收：隔离数据、诊断里程碑和实际进程资源。

不操作界面：收起和再次展开通过人工或 CUA 完成。测量结果进入 build/。
"""

import argparse
import ctypes
import datetime
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

MACOS_DIR = Path(__file__).resolve().parent.parent
PREFIX = "FROG_DIAGNOSTIC "
BUNDLE_ID = "cn.arsenalxj.Frog"


def save_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def make_fixture(directory, count):
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "bookmarks.json"
    if target.exists():
        raise RuntimeError(f"已有数据文件，未覆盖：{target}")
    bookmarks = [{
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"frog-performance/{index}")),
        "title": f"测试书签 {index + 1:04d}",
        "url": f"https://example.com/bookmark/{index + 1}",
        "groupId": None,
        "order": index,
        "createdAt": 1788912000000,
    } for index in range(count)]
    save_json(target, {"format": "frog-bookmarks", "schemaVersion": 1,
                       "groups": [], "bookmarks": bookmarks})
    return directory


def read_events(run):
    events = []
    for line in Path(run["log_path"]).read_text(errors="replace").splitlines():
        if line.startswith(PREFIX):
            try:
                event = json.loads(line[len(PREFIX):])
                if event.get("pid") == run["pid"]:
                    events.append(event)
            except json.JSONDecodeError:
                continue
    return events


def load_run(path):
    path = Path(path).resolve()
    return path, json.loads(path.read_text())


def frog_bundle_for_executable(executable):
    """将进程真实可执行路径与完整青蛙导航应用标识一并核对。"""
    executable = Path(executable).resolve()
    if executable.name != "Frog" or executable.parent.name != "MacOS":
        return None
    contents = executable.parent.parent
    if contents.name != "Contents" or contents.parent.suffix != ".app":
        return None
    try:
        with (contents / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "Frog":
        return None
    return contents.parent


def existing_app_processes():
    """同名模拟程序不视为青蛙导航；只读取状态，不终止任何进程。"""
    candidate = subprocess.run(["/usr/bin/pgrep", "-x", "Frog"], capture_output=True, text=True)
    if candidate.returncode not in (0, 1):
        raise RuntimeError(f"无法检查已有青蛙导航进程：{candidate.stderr.strip()}")
    running, ignored = [], []
    for value in candidate.stdout.split():
        pid = int(value)
        result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "comm="],
                                capture_output=True, text=True)
        executable = result.stdout.strip()
        if result.returncode != 0 or not executable:
            continue  # 进程在两次读取之间退出。
        app = frog_bundle_for_executable(executable)
        item = {"pid": pid, "executable": executable}
        if app:
            item["app"] = str(app)
            running.append(item)
        else:
            item["reason"] = "可执行路径或 Info.plist 不属于已知青蛙导航应用"
            ignored.append(item)
    return running, ignored


def launch(args):
    running, ignored = existing_app_processes()
    if running:
        details = "、".join(f"{item['app']}（PID {item['pid']}）" for item in running)
        raise RuntimeError(f"青蛙导航正在运行：{details}；请先在应用内按 Command-Q 退出，避免测到旧进程。")
    app = Path(args.app).resolve()
    executable = app / "Contents/MacOS/Frog"
    if not executable.is_file():
        raise RuntimeError(f"未找到可执行文件：{executable}")
    if frog_bundle_for_executable(executable) != app:
        raise RuntimeError(f"目标不是标识为 {BUNDLE_ID} 的完整青蛙导航应用：{app}")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).strip()
    if architecture != "arm64":
        raise RuntimeError(f"验收要求 arm64 Release，当前架构为 {architecture}。")
    # 只创建脚本自己的测试目录；应用的目录记忆和页码均由隔离参数关闭。
    fixture = make_fixture(Path(tempfile.mkdtemp(prefix="frog-perf-")), args.count)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    output = MACOS_DIR / "build/performance" / f"{stamp}-{os.getpid()}"
    output.mkdir(parents=True)
    log_path = output / "application.log"
    run_path = output / "run.json"
    with log_path.open("wb") as log:
        started_ns = time.monotonic_ns()
        process = subprocess.Popen([str(executable), "--data-directory", str(fixture),
                                    "--offline", "--diagnostics"], stdout=log, stderr=log,
                                   start_new_session=True)
    run = {"created_at": datetime.datetime.now().astimezone().isoformat(),
           "pid": process.pid, "app": str(app), "data_directory": str(fixture),
           "bookmark_count": args.count, "offline": True, "architecture": architecture,
           "os": platform.platform(), "log_path": str(log_path),
           "ignored_same_name_processes": ignored,
           "launch_method": "直接执行 Release .app 内二进制；包含进程创建和动态装载时间",
           "launch_monotonic_ns": started_ns}
    save_json(run_path, run)
    print(f"已启动隔离验收进程 {process.pid}；记录：{run_path}", flush=True)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        first = next((e for e in read_events(run) if e["event"] == "first_interactive"), None)
        if first:
            run["first_interactive_in_process_ms"] = first["elapsed_ms"]
            run["cold_launch_observed_wall_ms"] = (time.monotonic_ns() - started_ns) / 1_000_000
            run["cold_launch_observation_resolution_ms"] = 10
            save_json(run_path, run)
            print(f"冷启动可操作观测值：{run['cold_launch_observed_wall_ms']:.2f} ms；"
                  f"应用内部：{first['elapsed_ms']:.2f} ms", flush=True)
            print("请在界面确认可操作，然后收起；用 hidden 子命令测隐藏资源，再点击 Dock 展开。")
            return
        if process.poll() is not None:
            raise RuntimeError(f"进程提前退出（{process.returncode}）；日志：{log_path}")
        time.sleep(0.01)
    raise RuntimeError(f"15 秒内未收到 first_interactive。进程仍保留供检查；日志：{log_path}")


class RUsageV0(ctypes.Structure):
    # 对应 macOS SDK sys/resource.h 的 rusage_info_v0；CPU 字段采用 Mach timebase。
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "idle_wakeups", "interrupt_wakeups", "pageins",
        "wired_size", "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime")]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def resource_reader():
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    timebase = MachTimebase()
    system.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
    if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or timebase.denom == 0:
        raise RuntimeError("无法读取 Mach 时间基准。")

    def read(pid):
        result = RUsageV0()
        if libproc.proc_pid_rusage(pid, 0, ctypes.byref(result)) != 0:
            raise OSError(ctypes.get_errno(), f"无法读取进程 {pid} 的资源使用")
        return {"observed_monotonic_ns": time.monotonic_ns(),
                "cpu_time_ns": (result.user_time + result.system_time) * timebase.numer / timebase.denom,
                "physical_footprint_bytes": result.phys_footprint,
                "resident_size_bytes": result.resident_size,
                "process_start_abstime": result.proc_start_abstime}
    return read


def last_visibility_event(run):
    return next((e for e in reversed(read_events(run))
                 if e["event"] in ("first_interactive", "expand_interactive", "did_hide")), None)


def hidden(args):
    path, run = load_run(args.run)
    event = last_visibility_event(run)
    if not event or event["event"] != "did_hide":
        raise RuntimeError("诊断日志未确认窗口已收起，请先在青蛙导航界面按 Esc 收起。")
    hide_marker = event.copy()
    reader = resource_reader()
    start_identity = reader(run["pid"])["process_start_abstime"]
    print(f"窗口已收起；从现在起等待 {args.settle_seconds:g} 秒，再采样 {args.sample_seconds:g} 秒。", flush=True)
    settle_deadline = time.monotonic() + args.settle_seconds
    while time.monotonic() < settle_deadline:
        if last_visibility_event(run) != hide_marker:
            raise RuntimeError("等待期间窗口展示状态发生变化，此次隐藏测量无效。")
        if reader(run["pid"])["process_start_abstime"] != start_identity:
            raise RuntimeError("进程已被替换，此次测量无效。")
        time.sleep(min(0.25, max(0, settle_deadline - time.monotonic())))
    samples = [reader(run["pid"])]
    deadline = time.monotonic() + args.sample_seconds
    while time.monotonic() < deadline:
        time.sleep(min(1, max(0, deadline - time.monotonic())))
        if last_visibility_event(run) != hide_marker:
            raise RuntimeError("采样期间窗口展示状态发生变化，此次隐藏测量无效。")
        current = reader(run["pid"])
        if current["process_start_abstime"] != start_identity:
            raise RuntimeError("进程已被替换，此次测量无效。")
        samples.append(current)
    first, last = samples[0], samples[-1]
    cpu_percent = ((last["cpu_time_ns"] - first["cpu_time_ns"]) /
                   (last["observed_monotonic_ns"] - first["observed_monotonic_ns"])) * 100
    measurement = {"settle_seconds": args.settle_seconds,
                   "sample_seconds": (last["observed_monotonic_ns"] - first["observed_monotonic_ns"]) / 1e9,
                   "idle_cpu_percent": cpu_percent,
                   "physical_footprint_mb_after_settle": first["physical_footprint_bytes"] / 1_000_000,
                   "physical_footprint_mb_max": max(s["physical_footprint_bytes"] for s in samples) / 1_000_000,
                   "memory_definition": "libproc rusage_info_v0.ri_phys_footprint；十进制 MB",
                   "cpu_definition": "用户+内核 Mach CPU时间差，按 mach_timebase_info 换算；单核满载为100%",
                   "samples": samples}
    run["hidden_measurement"] = measurement
    save_json(path, run)
    print(json.dumps({k: v for k, v in measurement.items() if k != "samples"}, ensure_ascii=False, indent=2))


def report(args):
    path, run = load_run(args.run)
    events = read_events(run)
    run["diagnostic_events"] = events
    run["reopen_interactive_ms"] = [e["elapsed_ms"] for e in events if e["event"] == "expand_interactive"]
    cold = run.get("cold_launch_observed_wall_ms")
    hidden_measurement = run.get("hidden_measurement")
    reopen = run["reopen_interactive_ms"]
    thousand_bookmarks = run.get("bookmark_count") == 1000
    standard_hidden_sample = (hidden_measurement and hidden_measurement["settle_seconds"] >= 30
                              and hidden_measurement["sample_seconds"] >= 10)
    run["targets"] = {
        "cold_launch_le_1000_ms": None if cold is None or not thousand_bookmarks else cold <= 1000,
        "reopen_le_150_ms": None if not reopen or not thousand_bookmarks else max(reopen) <= 150,
        "hidden_physical_le_100_mb": None if not standard_hidden_sample or not thousand_bookmarks else hidden_measurement["physical_footprint_mb_max"] <= 100,
        "hidden_cpu_le_1_percent": None if not standard_hidden_sample or not thousand_bookmarks else hidden_measurement["idle_cpu_percent"] <= 1,
    }
    run["measurement_boundary"] = (
        "可操作事件在数据载入、窗口可见后的主线程下一轮布局完成时输出；"
        "不代表展开动画结束，也不代替人工/CUA点击验收。"
        "冷启动为新进程启动，未清理系统文件缓存；再次展开从应用收到展开请求起算，"
        "不包含Dock事件传递时间。缺少测量项以null记录。")
    save_json(path, run)
    print(json.dumps(run, ensure_ascii=False, indent=2))


def positive(value):
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("必须大于 0")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    fixture = commands.add_parser("fixture", help="在指定空目录创建隔离书签数据")
    fixture.add_argument("directory", type=Path)
    fixture.add_argument("--count", type=int, default=1000)
    start = commands.add_parser("launch", help="创建隔离数据并启动 Release 应用，记录冷启动")
    start.add_argument("--app", default=str(MACOS_DIR / "build/青蛙导航.app"))
    start.add_argument("--count", type=int, default=1000)
    hidden_parser = commands.add_parser("hidden", help="窗口由人工/CUA收起后，测隐藏内存与CPU")
    hidden_parser.add_argument("--run", required=True)
    hidden_parser.add_argument("--settle-seconds", type=positive, default=30)
    hidden_parser.add_argument("--sample-seconds", type=positive, default=10)
    report_parser = commands.add_parser("report", help="汇总冷启动、再次展开和资源测量；缺失项留空")
    report_parser.add_argument("--run", required=True)
    args = parser.parse_args()
    if getattr(args, "count", 1) < 1:
        parser.error("书签数量必须大于 0")
    try:
        if args.command == "fixture":
            print(make_fixture(args.directory.resolve(), args.count))
        elif args.command == "launch":
            launch(args)
        elif args.command == "hidden":
            hidden(args)
        else:
            report(args)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"验收未完成：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
