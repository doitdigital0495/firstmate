#!/usr/bin/env python3
"""Deterministic dispatch_choices peer; never contacts a service or reads keys."""
import json
import os
import socket
import sys

path, response_file, log = sys.argv[1:]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen()
    calls = 0
    last_sequence = None
    while True:
        client, _ = server.accept()
        with client:
            request = bytearray()
            while b"\n" not in request:
                chunk = client.recv(65536)
                if not chunk:
                    break
                request.extend(chunk)
            parsed = json.loads(request)
            assert parsed["type"] == "dispatch_choices" and parsed["version"] == 1
            with open(log, "a", encoding="utf-8") as output:
                output.write(json.dumps(parsed) + "\n")
            with open(response_file, encoding="utf-8") as fixture:
                response = json.load(fixture)
            if "_stubResponses" in response:
                sequence = response["_stubResponses"]
                if sequence != last_sequence:
                    calls = 0
                    last_sequence = sequence
                response = sequence[min(calls, len(sequence) - 1)]
            calls += 1
            if "_stubMutate" in response:
                mutation = response.pop("_stubMutate")
                with open(mutation["path"], "w", encoding="utf-8") as target:
                    target.write(mutation["text"])
            try:
                client.sendall(json.dumps({"type": "dispatch_choices", "version": 1,
                                           "requestId": "stub-dispatch-1",
                                           "response": response}).encode() + b"\n")
            except BrokenPipeError:
                pass
