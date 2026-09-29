#!/usr/bin/env python3
"""A stand-in portal for the hermetic guards in base/tests (DEV-51).

Listens on 127.0.0.1 on a free port, prints that port on the first line of stdout, and records every
POST as one JSON line in the log file: method, path, query, the headers a hook sets, and the body —
gunzipped when it was sent as application/gzip, so a guard can compare it byte for byte with the
transcript the hook read. Never talks to anything else.

The answer comes from the mode file, re-read on every request so a guard can switch it between two
firings: `200` (the default), `500`, or `hang` (the request is recorded first, then held for 20 s).

    python3 stub-portal.py <mode-file> <log-file>
"""
import gzip
import http.server
import json
import os
import sys
import time
from urllib.parse import parse_qs, urlsplit

MODE_FILE, LOG_FILE = sys.argv[1], sys.argv[2]


def mode():
    try:
        with open(MODE_FILE) as f:
            return f.read().strip() or "200"
    except OSError:
        return "200"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        ctype = self.headers.get("Content-Type", "")
        url = urlsplit(self.path)
        rec = {
            "method": "POST",
            "path": url.path,
            "query": {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()},
            "headers": {
                "authorization": self.headers.get("Authorization"),
                "x-agent-name": self.headers.get("X-Agent-Name"),
                "content-type": ctype,
            },
            "bytes": length,
        }
        try:
            data = gzip.decompress(raw) if ctype == "application/gzip" else raw
            rec["body"] = data.decode("utf-8", "replace")
        except Exception as exc:  # a body that is not what it claims — record it, never crash
            rec["body_error"] = str(exc)
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(rec) + "\n")
        m = mode()
        if m == "hang":
            time.sleep(20)
        code = 500 if m == "500" else 200
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}' if code == 200 else b'{"error":"stub"}')
        except OSError:
            pass  # the client gave up (its --max-time) — expected in the hang mode

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_address[1], flush=True)
server.serve_forever()
