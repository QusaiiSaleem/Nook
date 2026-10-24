#!/usr/bin/env python3
"""Tiny client for Nook's DevMCP server. Usage: mcp.py <tool> [json-args]  |  mcp.py --list"""
import json, os, sys, urllib.request
TOKEN = open(os.path.expanduser("~/Library/Application Support/com.qusai.nook/dev-mcp-token")).read().strip()
URL = "http://127.0.0.1:47823/mcp"
def rpc(method, params=None, rid=1):
    body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())
if __name__ == "__main__":
    init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}})
    if sys.argv[1:] == ["--list"]:
        print("server:", init["result"]["serverInfo"])
        tools = rpc("tools/list", rid=2)["result"]["tools"]
        print(len(tools), "tools:", ", ".join(t["name"] for t in tools))
    else:
        res = rpc("tools/call", {"name": sys.argv[1], "arguments": json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}}, rid=3)
        for c in res.get("result", {}).get("content", []):
            print(c.get("text", f"<{c.get('type')} {len(c.get('data',''))} bytes>")[:1500])
        if "error" in res: print("ERROR", res["error"])
