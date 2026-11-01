#!/usr/bin/env python3
"""Usage: python3 fm-dispatch-bounded.py DEADLINE_EPOCH COMMAND [ARG ...].

Bound a quota read/warm-up and its subprocess group to 180s or the earlier
absolute deadline; 0 means no shared deadline. Exit 124 on timeout.
"""
import os
import signal
import subprocess
import sys
import time


def main():
    deadline = int(sys.argv[1])
    remaining = min(180, deadline - time.time()) if deadline else 180
    if remaining <= 0:
        return 124
    with subprocess.Popen(sys.argv[2:], start_new_session=True) as process:
        try:
            return process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 124


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError:
        print("dispatch quota read/warm-up unavailable", file=sys.stderr)
        sys.exit(1)
