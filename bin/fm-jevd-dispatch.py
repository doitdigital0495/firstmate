#!/usr/bin/env python3
"""Private transport: python3 fm-jevd-dispatch.py SOCKET < request.json.

Protocol owned by docs/configuration.md; reply body on stdout, exit 1 on failure.
"""
import json
import os
import socket
import stat
import sys
import time


def main():
    path = sys.argv[1]
    info = os.stat(path, follow_symlinks=False)
    if not stat.S_ISSOCK(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("jevd socket must be a 0600 unix socket")
    if info.st_uid != os.getuid():
        raise ValueError("jevd socket must belong to this user")
    request = {"type": "dispatch_choices", "version": 1,
               "request": json.load(sys.stdin)}
    deadline = time.monotonic() + 5
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(max(0.001, deadline - time.monotonic()))
        client.connect(path)
        client.settimeout(max(0.001, deadline - time.monotonic()))
        client.sendall(json.dumps(request).encode() + b"\n")
        reply = bytearray()
        while b"\n" not in reply:
            if time.monotonic() >= deadline:
                raise ValueError("jevd reply deadline expired")
            client.settimeout(deadline - time.monotonic())
            chunk = client.recv(65536)
            if not chunk or len(reply) + len(chunk) > 1048576:
                raise ValueError("invalid jevd reply length")
            reply.extend(chunk)
    envelope = json.loads(reply.split(b"\n", 1)[0])
    if not isinstance(envelope, dict):
        raise ValueError("invalid jevd envelope")
    if envelope.get("type") != "dispatch_choices" or envelope.get("version") != 1:
        raise ValueError("unsupported jevd reply")
    request_id = envelope.get("requestId")
    if not isinstance(request_id, str) or not request_id.strip():
        raise ValueError("missing jevd request id")
    response = envelope["response"]
    if not isinstance(response, dict):
        raise ValueError("invalid jevd response")
    response["requestId"] = request_id
    print(json.dumps(response))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        # Never echo peer-controlled text or request content into an error.
        print("jevd dispatch unavailable or invalid reply", file=sys.stderr)
        sys.exit(1)
