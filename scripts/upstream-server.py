#!/usr/bin/env python3
"""Local HTTP upstream for the Wget/v1 demo (stdlib only).

Serves --root and, per request, adds a Content-Digest header (RFC 9530) whose
mode is read from --digest-file: none, sha-256, sha-512 or wrong. With
--auth-file, every path except /-/ready requires Basic auth. With --auth-log,
every request is appended to FILE as method, path and Basic username; without
--auth-file, requests that carry no credentials get a 401 challenge.
"""

import argparse
import base64
import binascii
import functools
import hashlib
import http.server
import os
import sys
import threading


class UpstreamHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def end_headers(self):
        if self.content_digest:
            self.send_header("Content-Digest", self.content_digest)
        super().end_headers()

    def do_GET(self):
        if self._prepare():
            super().do_GET()

    def do_HEAD(self):
        if self._prepare():
            super().do_HEAD()

    def _prepare(self):
        self.content_digest = None
        path = self.path.split("?", 1)[0]
        if path == "/-/ready":
            self._empty(204)
            return False
        if self.server.auth_log:
            with self.server.auth_log_lock, open(self.server.auth_log, "a", encoding="utf-8") as f:
                f.write(f"{self.command}\t{self.path}\t{self._basic_user()}\n")
        if self.server.auth is not None and self.headers.get("Authorization") != "Basic " + self.server.auth:
            self._unauthorized("upstream")
            return False
        if self.server.auth is None and self.server.auth_log and self._basic_user() == "-":
            self._unauthorized("demo")
            return False
        self.content_digest = self._digest_header(path)
        return True

    def _basic_user(self):
        header = self.headers.get("Authorization")
        if header is None:
            return "-"
        if not header.startswith("Basic "):
            return "?"
        try:
            creds = base64.b64decode(header[len("Basic "):], validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError):
            return "?"
        return creds.split(":", 1)[0]

    def _unauthorized(self, realm):
        self.send_response(401)
        self.send_header("WWW-Authenticate", f'Basic realm="{realm}"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _digest_header(self, path):
        with open(self.server.digest_file, encoding="utf-8") as f:
            mode = f.read().strip()
        if mode == "none":
            return None
        if mode == "wrong":
            return "sha-256=:" + base64.b64encode(hashlib.sha256(b"wrong").digest()).decode() + ":"
        if mode not in ("sha-256", "sha-512"):
            raise ValueError(f"unknown digest mode: {mode}")
        fs_path = self.translate_path(path)
        if not os.path.isfile(fs_path):
            return None
        with open(fs_path, "rb") as f:
            digest = hashlib.new(mode.replace("-", ""), f.read()).digest()
        return f"{mode}=:" + base64.b64encode(digest).decode() + ":"


def read_auth(path):
    with open(path, encoding="utf-8") as f:
        creds = f.readline().rstrip("\n")
    if ":" not in creds:
        raise ValueError("auth file must contain user:password")
    return base64.b64encode(creds.encode()).decode()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--digest-file", required=True)
    parser.add_argument("--auth-file")
    parser.add_argument("--auth-log")
    args = parser.parse_args(argv)

    try:
        auth = read_auth(args.auth_file) if args.auth_file else None
    except (OSError, ValueError) as err:
        print(f"upstream-server: {err}", file=sys.stderr)
        return 1

    handler = functools.partial(UpstreamHandler, directory=args.root)
    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    except OSError as err:
        print(f"upstream-server: cannot bind 127.0.0.1:{args.port}: {err}", file=sys.stderr)
        return 1

    server.digest_file = args.digest_file
    server.auth = auth
    server.auth_log = args.auth_log
    server.auth_log_lock = threading.Lock()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
