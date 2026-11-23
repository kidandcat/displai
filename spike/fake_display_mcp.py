"""Minimal stdio MCP server that mimics Minerva's display tools for the spike.

It only logs when each tool call arrives (wall-clock epoch seconds) to the file
given in MINERVA_SPIKE_LOG, so the e2e script can measure when the screen
would update.
"""

import json
import os
import sys
import time

LOG = os.environ.get("MINERVA_SPIKE_LOG", "/tmp/minerva_spike_mcp.log")

TOOLS = [
    {
        "name": "show",
        "description": "Show content on the user's display. Use for anything visual: cards, lists, tables. "
                       "Replaces the current view.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "cards": {"type": "array", "items": {"type": "object", "properties": {
                    "title": {"type": "string"}, "body": {"type": "string"}}}},
            },
            "required": ["title"],
        },
    },
    {
        "name": "get_state",
        "description": "Return the current display state as a compact widget tree.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def reply(id_, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": id_, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    msg = json.loads(line)
    m = msg.get("method")
    if m == "initialize":
        reply(msg["id"], {"protocolVersion": msg["params"].get("protocolVersion", "2025-06-18"),
                          "capabilities": {"tools": {}},
                          "serverInfo": {"name": "minerva", "version": "0.0.1"}})
    elif m == "tools/list":
        reply(msg["id"], {"tools": TOOLS})
    elif m == "tools/call":
        with open(LOG, "a") as f:
            f.write(json.dumps({"t": time.time(), "tool": msg["params"]["name"]}) + "\n")
        reply(msg["id"], {"content": [{"type": "text", "text": "ok"}]})
    elif "id" in msg:
        reply(msg["id"], {})
