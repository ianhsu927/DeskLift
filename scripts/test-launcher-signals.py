#!/usr/bin/env python3
"""Offline subprocess regression tests for DeskLift GUIProcessSignals.

The caller supplies the already compiled Swift fixture. Every tested descriptor
is a local anonymous pipe or AF_UNIX socketpair; no app, Bluetooth manager,
credentials, lamp, IP socket, or network API is used.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

_TIMEOUT = 4


def close_all(descriptors):
    for descriptor in descriptors:
        try:
            os.close(descriptor)
        except OSError:
            pass


def ready(fd):
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_READ)
        if not selector.select(_TIMEOUT) or os.read(fd, 1) != b"R":
            raise AssertionError("fixture did not become ready within the bound")


def wait(child):
    try:
        stdout, stderr = child.communicate(timeout=_TIMEOUT)
        return child.returncode, stdout, stderr
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate(timeout=_TIMEOUT)
        raise AssertionError("fixture did not finish within the bound") from None


def stop(child):
    if child is not None and child.poll() is None:
        child.kill()
        child.communicate(timeout=_TIMEOUT)


def broken_case(fixture, mode, target, delayed):
    descriptors = []
    child = None
    try:
        result_read, result_write = os.pipe()
        descriptors += [result_read, result_write]
        inherited = [result_write]
        command = [str(fixture), mode, "--target", target, "--result-fd", str(result_write)]
        stdout = stderr = subprocess.PIPE
        broken_read = broken_write = go_write = None
        if target in ("stdout", "stderr"):
            broken_read, broken_write = os.pipe()
            descriptors += [broken_read, broken_write]
            if target == "stdout":
                stdout = broken_write
            else:
                stderr = broken_write
            if not delayed:
                os.close(broken_read)
                descriptors.remove(broken_read)
                broken_read = None
        if delayed:
            ready_read, ready_write = os.pipe()
            go_read, go_write = os.pipe()
            descriptors += [ready_read, ready_write, go_read, go_write]
            inherited += [ready_write, go_read]
            command += ["--ready-fd", str(ready_write), "--go-fd", str(go_read)]
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                 pass_fds=tuple(inherited), close_fds=True, restore_signals=True)
        # Parent must not keep a writer open, or a child's death would not
        # deliver EOF on the independent result pipe.
        for descriptor in inherited + ([broken_write] if broken_write is not None else []):
            os.close(descriptor)
            descriptors.remove(descriptor)
        if delayed:
            ready(ready_read)
            os.close(broken_read)
            descriptors.remove(broken_read)
            os.write(go_write, b"G")
            os.close(go_write)
            descriptors.remove(go_write)
        returncode, _, _ = wait(child)
        result = os.read(result_read, 64)
        if mode == "--cli":
            assert returncode == -signal.SIGPIPE, f"baseline returned {returncode}, expected SIGPIPE"
            assert result == b"", "baseline unexpectedly reported an EPIPE recovery"
        else:
            assert returncode == 0, f"protected GUI returned {returncode}"
            assert result == b"EPIPE\n", "protected GUI did not receive/report EPIPE"
    finally:
        stop(child)
        close_all(descriptors)


def healthy_case(fixture, mode):
    child = subprocess.Popen([str(fixture), mode, "--target", "healthy"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, restore_signals=True)
    try:
        returncode, stdout, stderr = wait(child)
        assert returncode == 0, f"healthy writer returned {returncode}"
        assert stdout == b"fixture stdout\n", "stdout changed"
        assert stderr == b"fixture stderr\n", "stderr changed"
    finally:
        stop(child)


def sigterm_case(fixture, mode):
    read_fd, write_fd = os.pipe()
    child = None
    try:
        child = subprocess.Popen([str(fixture), mode, "--target", "idle", "--ready-fd", str(write_fd)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 pass_fds=(write_fd,), close_fds=True, restore_signals=True)
        os.close(write_fd)
        write_fd = None
        ready(read_fd)
        child.terminate()
        returncode, _, _ = wait(child)
        assert returncode == -signal.SIGTERM, f"SIGTERM semantics changed: {returncode}"
    finally:
        stop(child)
        close_all([read_fd] + ([write_fd] if write_fd is not None else []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path, help="Already compiled LauncherSignalFixture executable")
    args = parser.parse_args()
    fixture = args.fixture.resolve()
    if not fixture.is_file() or not os.access(fixture, os.X_OK):
        parser.error("fixture executable is unavailable")
    cases = []
    for mode in ("--cli", "--gui"):
        for target in ("stdout", "stderr", "socket"):
            cases.append((mode[2:] + "_broken_" + target,
                          lambda m=mode, t=target: broken_case(fixture, m, t, False)))
        for target in ("stdout", "stderr"):
            cases.append((mode[2:] + "_disconnect_after_ready_" + target,
                          lambda m=mode, t=target: broken_case(fixture, m, t, True)))
        cases.append((mode[2:] + "_healthy_output", lambda m=mode: healthy_case(fixture, m)))
        cases.append((mode[2:] + "_sigterm", lambda m=mode: sigterm_case(fixture, m)))
    failed = []
    for name, case in cases:
        try:
            case()
            print("PASS " + name, flush=True)
        except (AssertionError, OSError, subprocess.SubprocessError) as error:
            failed.append(name)
            print("FAIL " + name + ": " + str(error), file=sys.stderr, flush=True)
    print(f"{len(cases) - len(failed)}/{len(cases)} launcher signal checks passed", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
