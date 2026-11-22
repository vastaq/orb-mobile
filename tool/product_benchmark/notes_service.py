"""Loopback-only MCP notebook for the cross-app confirmation integration test."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Notebook(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def response(self, status, value=None):
        data = b"" if value is None else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/state":
            return self.response(404)
        self.response(200, json.loads(self.server.note.read_text()))

    def do_POST(self):
        if self.path != "/mcp":
            return self.response(404)
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 65536:
            return self.response(400)
        req = json.loads(self.rfile.read(length))
        method = req.get("method")
        if method == "notifications/initialized":
            return self.response(202)
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "Orb test notebook", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [
                {"name": "read_note", "description": "Read the single notebook page.",
                 "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
                 "annotations": {"readOnlyHint": True}},
                {"name": "replace_note", "description": "Replace the whole notebook page with the exact requested text.",
                 "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}},
                                 "required": ["text"], "additionalProperties": False},
                 "annotations": {"readOnlyHint": False, "destructiveHint": True}},
            ]}
        elif method == "tools/call":
            state = json.loads(self.server.note.read_text())
            tool = req["params"]["name"]
            if tool == "replace_note":
                value = req["params"]["arguments"].get("text")
                if not isinstance(value, str) or len(value) > 4096:
                    return self.response(400)
                state = {"text": value, "writes": state["writes"] + 1}
                self.server.note.write_text(json.dumps(state, ensure_ascii=False))
            elif tool != "read_note":
                return self.response(400)
            result = {"content": [{"type": "text", "text": state["text"]}]}
        else:
            return self.response(400)
        self.response(200, {"jsonrpc": "2.0", "id": req["id"], "result": result})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True, help="New synthetic JSON file")
    parser.add_argument("--port", type=int, default=18965)
    args = parser.parse_args()
    with HTTPServer(("127.0.0.1", args.port), Notebook) as httpd:
        httpd.note = args.state
        with args.state.open("x") as output:
            json.dump({"text": "资料架是白色。", "writes": 0}, output, ensure_ascii=False)
        httpd.serve_forever()
