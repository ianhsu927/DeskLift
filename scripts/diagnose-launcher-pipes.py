#!/usr/bin/env python3
"""Observe a preview DeskLift GUI after its launcher's output pipes disappear.

Runs three bounded, sequential child processes: a /dev/null baseline, readers
already closed before launch, and readers closed one second after launch.
Each child receives only --preview, so this diagnostic never requests Bluetooth
or lamp access. It does not drive the UI, read credentials, or build the app.
The live child is terminated and waited for after each observation.

--send-sigpipe adds a synthetic signal-injection case against only one newly
spawned preview child. It does not identify the original triggering descriptor.

Example:
  python3 scripts/diagnose-launcher-pipes.py \
      --app /Applications/DeskLift.app --observe-seconds 3
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time
from zoneinfo import ZoneInfo


def signal_name(returncode: int | None) -> str | None:
    if returncode is None or returncode >= 0:
        return None
    try:
        return signal.Signals(-returncode).name
    except ValueError:
        return "SIGNAL_" + str(-returncode)


def run_case(name: str, command: list[str], *, observe_seconds: float,
             disconnect_after: float | None) -> dict:
    """Observe only; terminate and reap the specific preview child afterwards."""
    readers = []
    writers = []
    child = None
    before_cleanup = None
    after_cleanup = None
    launch_failed = False
    cleanup_action = None
    started = time.monotonic()
    try:
        if disconnect_after is None:
            stdout_target = stderr_target = subprocess.DEVNULL
        else:
            stdout_read, stdout_write = os.pipe()
            stderr_read, stderr_write = os.pipe()
            readers = [stdout_read, stderr_read]
            writers = [stdout_write, stderr_write]
            stdout_target, stderr_target = stdout_write, stderr_write
            if disconnect_after == 0:
                for descriptor in readers:
                    os.close(descriptor)
                readers.clear()
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                 stdout=stdout_target, stderr=stderr_target,
                                 close_fds=True, restore_signals=True,
                                 start_new_session=True)
        for descriptor in writers:
            os.close(descriptor)
        writers.clear()
        launched_at = time.monotonic()
        deadline = launched_at + observe_seconds
        while time.monotonic() < deadline:
            if readers and time.monotonic() >= launched_at + disconnect_after:
                for descriptor in readers:
                    os.close(descriptor)
                readers.clear()
            before_cleanup = child.poll()
            if before_cleanup is not None:
                break
            time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
        before_cleanup = child.poll()
    except OSError:
        launch_failed = True
    finally:
        for descriptor in readers + writers:
            os.close(descriptor)
        if child is not None:
            if child.poll() is None:
                cleanup_action = "SIGTERM"
                child.terminate()
                try:
                    after_cleanup = child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    cleanup_action = "SIGKILL_AFTER_SIGTERM_TIMEOUT"
                    child.kill()
                    after_cleanup = child.wait(timeout=2)
            else:
                after_cleanup = child.wait(timeout=2)
    survived = child is not None and not launch_failed and before_cleanup is None
    return {"name": name, "passed": survived,
            "launch_failed": launch_failed,
            "stdout_stderr": "DEVNULL" if disconnect_after is None else "pipe",
            "disconnect_after_seconds": disconnect_after,
            "observation_seconds": observe_seconds,
            "before_cleanup_returncode": before_cleanup,
            "before_cleanup_signal": signal_name(before_cleanup),
            "survived_observation": survived,
            "cleanup_action": cleanup_action,
            "after_cleanup_returncode": after_cleanup,
            "after_cleanup_signal": signal_name(after_cleanup),
            "elapsed_seconds": round(time.monotonic() - started, 3)}



def run_synthetic_sigpipe_case(command: list[str]) -> dict:
    """Inject once into our own new child; never discover or signal other apps."""
    child = None
    before_cleanup = None
    after_cleanup = None
    cleanup_action = None
    launch_failed = False
    injected = False
    survived = False
    injected_after = None
    started = time.monotonic()
    try:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 close_fds=True, restore_signals=True,
                                 start_new_session=True)
        launched_at = time.monotonic()
        injection_time = launched_at + 1
        while time.monotonic() < injection_time and child.poll() is None:
            time.sleep(min(0.05, max(0.0, injection_time - time.monotonic())))
        before_cleanup = child.poll()
        if before_cleanup is None:
            # This PID comes directly from this Popen. The child has not been
            # reaped, so this cannot address a reused PID or an existing app.
            os.kill(child.pid, signal.SIGPIPE)
            injected = True
            injected_after = round(time.monotonic() - launched_at, 3)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and child.poll() is None:
                time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
            before_cleanup = child.poll()
            survived = before_cleanup is None
    except OSError:
        launch_failed = True
    finally:
        if child is not None:
            if child.poll() is None:
                cleanup_action = "SIGTERM"
                child.terminate()
                try:
                    after_cleanup = child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    cleanup_action = "SIGKILL_AFTER_SIGTERM_TIMEOUT"
                    child.kill()
                    after_cleanup = child.wait(timeout=2)
            else:
                after_cleanup = child.wait(timeout=2)
    return {"name": "synthetic_sigpipe_injection",
            "classification": "synthetic signal injection",
            "original_triggering_descriptor_identified": False,
            "passed": injected and survived and not launch_failed,
            "launch_failed": launch_failed,
            "child_pid": child.pid if child is not None else None,
            "signal_injected_once": injected,
            "injected_after_seconds": injected_after,
            "post_injection_observation_seconds": 2,
            "before_cleanup_returncode": before_cleanup,
            "before_cleanup_signal": signal_name(before_cleanup),
            "survived_observation": survived,
            "cleanup_action": cleanup_action,
            "after_cleanup_returncode": after_cleanup,
            "after_cleanup_signal": signal_name(after_cleanup),
            "elapsed_seconds": round(time.monotonic() - started, 3)}


def executable_from_bundle(bundle: Path) -> Path:
    bundle = bundle.expanduser().resolve()
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        raise ValueError("Invalid application executable")
    path = bundle / "Contents/MacOS" / executable
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError("Application executable is not available")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, type=Path, help="Absolute path of an already built DeskLift.app")
    parser.add_argument("--observe-seconds", type=float, default=3,
                        help="Total observation duration per child, including the first second before delayed disconnect")
    parser.add_argument("--send-sigpipe", action="store_true",
                        help="Add one synthetic SIGPIPE injection into a newly spawned preview child only")
    parser.add_argument("--output", type=Path,
                        help="JSON report path; a Shanghai timestamp is prepended if the filename has none")
    args = parser.parse_args()
    if not args.app.is_absolute():
        parser.error("--app must be an absolute application bundle path")
    if not 1.5 <= args.observe_seconds <= 30:
        parser.error("--observe-seconds must be between 1.5 and 30 seconds")
    try:
        executable = executable_from_bundle(args.app)
    except (OSError, ValueError, plistlib.InvalidFileException):
        parser.error("Cannot read the selected application bundle")
    command = [str(executable), "--preview"]
    cases = [run_case(name, command, observe_seconds=args.observe_seconds, disconnect_after=delay)
             for name, delay in (("devnull_baseline", None),
                                 ("pipe_readers_closed_before_launch", 0),
                                 ("pipe_readers_closed_after_one_second", 1))]
    if args.send_sigpipe:
        cases.append(run_synthetic_sigpipe_case(command))
    stamp = datetime.datetime.now(ZoneInfo("Asia/Shanghai"))
    prefix = stamp.strftime("%Y%m%d-%H%M%S")
    path = args.output or Path("build/diagnostics") / (prefix + "-launcher-pipes.json")
    if not re.match(r"^\d{8}-\d{6}(?:[-.]|$)", path.name):
        path = path.with_name(prefix + "-" + path.name)
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    report = {"timestamp": stamp.isoformat(), "application": str(args.app.resolve()),
              "app_arguments": ["--preview"], "hardware_access_requested": False,
              "synthetic_signal_injection_requested": args.send_sigpipe,
              "original_triggering_descriptor_identified": False,
              "gui_panel_interaction_verified": False,
              "passed": all(case["passed"] for case in cases), "cases": cases}
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps({"passed": report["passed"], "report_path": str(path), "cases": cases},
                     ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
