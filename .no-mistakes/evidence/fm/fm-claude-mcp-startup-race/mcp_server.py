#!/usr/bin/env python3
# Disposable stdio MCP server: one tool `ping` -> MCP_PROVED, optional startup sleep.
import json, sys, time
time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 0)
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    mid, method = msg.get("id"), msg.get("method")
    if mid is None:
        continue
    if method == "initialize":
        res = {"protocolVersion": msg["params"].get("protocolVersion", "2024-11-05"),
               "capabilities": {"tools": {}}, "serverInfo": {"name": "task-only-marker", "version": "1"}}
    elif method == "tools/list":
        res = {"tools": [{"name": "ping", "description": "Returns a marker string.",
                          "inputSchema": {"type": "object", "properties": {}}}]}
    elif method == "tools/call":
        res = {"content": [{"type": "text", "text": "MCP_PROVED"}]}
    else:
        res = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": res}) + "\n")
    sys.stdout.flush()
