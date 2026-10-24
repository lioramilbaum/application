#!/usr/bin/env python3
"""Local RFC 3161 time-stamp authority for the GPG demo (stdlib only).

POST / answers a time-stamp query with `openssl ts -reply`. GET /-/ready answers
readiness probes. Every POST is appended to --log. Binds to 127.0.0.1 only.
Run with: python3 -I scripts/tsa-server.py --port PORT --config CNF --section SEC --log LOG
"""
import argparse
import http.server
import os
import subprocess
import tempfile


def main():
    ap = argparse.ArgumentParser(description="Local RFC 3161 time-stamp authority")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--config", required=True, help="openssl config file with the [ tsa ] sections")
    ap.add_argument("--section", required=True, help="openssl config section for ts -reply")
    ap.add_argument("--log", required=True, help="file that records each POST")
    args = ap.parse_args()

    class Handler(http.server.BaseHTTPRequestHandler):
        def _reply(self, status, content_type, body):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/-/ready":
                self._reply(200, "text/plain", b"ready\n")
            else:
                self._reply(404, "text/plain", b"not found\n")

        def do_POST(self):
            content_length = self.headers.get("Content-Length")
            body = self.rfile.read(int(content_length)) if content_length else self.rfile.read(4096)
            content_type = self.headers.get("Content-Type", "")
            with open(args.log, "a") as log:
                log.write(f"POST {self.path} {content_type}\n")
            if self.path != "/":
                self._reply(404, "text/plain", b"not found\n")
                return

            fd, query = tempfile.mkstemp(prefix="tsa-query-")
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(body)
                proc = subprocess.run(
                    ["openssl", "ts", "-reply", "-config", args.config,
                     "-section", args.section, "-queryfile", query],
                    capture_output=True,
                )
            finally:
                os.unlink(query)

            if proc.returncode == 0:
                self._reply(200, "application/timestamp-reply", proc.stdout)
            else:
                stderr_text = proc.stderr or b"openssl ts -reply failed\n"
                with open(args.log, "a") as log:
                    log.write(f"openssl error: {stderr_text.decode(errors='replace')}\n")
                self._reply(500, "text/plain", stderr_text)

        def log_message(self, fmt, *log_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
