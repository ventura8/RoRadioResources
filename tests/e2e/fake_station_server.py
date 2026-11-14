# Copyright 2026 Sergiu Alexandrescu
r"""A fake of everything the weekly refresh talks to, on 127.0.0.1, for tests/Refresh.E2E.Tests.ps1.

It serves streams (audio, ICY, HLS, HTML, HTTP errors, redirects), the pages the refresh scrapes (myradioonline.ro's
sitemap and station pages, radio-browser.info, the Shoutcast directory and its playlists, radio.net, Icecast status
pages) and logo images, all from one JSON file of routes:

    [{"path": "/stream/ok", "type": "audio/mpeg", "audio": 8192},
     {"path": "/old", "status": 404, "body": "gone"},
     {"path": "/moved", "status": 302, "headers": {"Location": "{base}/stream/ok"}},
     {"path": "/icy", "icy": "ICY 200 OK\r\ncontent-type: audio/aacp\r\n\r\n", "audio": 4096},
     {"path": "/json/stations/search", "query": "name=Radio%20Beta", "type": "application/json", "body": "[]"}]

A route matches on its method (GET by default), its path and, when it has one, a piece of the query string; the first
match answers. A route with "times" answers only that many requests, then leaves them to the next match. A POST
route with "record" appends each request body, one per line, to that file. "{base}"
in a body or a header is the server's own address. "file" sends a file's bytes. An unknown path answers 404.
The port is chosen by the system and written as the first line on stdout.

Usage: python fake_station_server.py ROUTES.json
"""

from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, ClassVar, override
from urllib.parse import urlsplit

# The script and its one argument.
_ARGUMENT_COUNT = 2

# The first bytes of an MPEG audio frame, repeated: what a probe reads looks like an MP3 stream.
_AUDIO_FRAME = bytes([0xFF, 0xFB, 0x90, 0x64]) + bytes(412)


def audio_bytes(count: int) -> bytes:
    """Return `count` bytes that start like MP3 frames."""
    frames = _AUDIO_FRAME * (count // len(_AUDIO_FRAME) + 1)
    return frames[:count]


class FakeHandler(BaseHTTPRequestHandler):
    """Answers every request from the route table."""

    routes: ClassVar[list[dict[str, Any]]] = []
    base: ClassVar[str] = ""

    @override
    def log_message(self, *args: object) -> None:
        """Keep the test output clean: requests are not logged."""

    @override
    def do_GET(self) -> None:
        """Answer a GET."""
        self._send(self._find("GET"))

    @override
    def do_POST(self) -> None:
        """Answer a POST; a route with "record" appends the body to that file (what Sentry was sent)."""
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        route = self._find("POST")
        if route is not None and "record" in route:
            with Path(route["record"]).open("ab") as record:
                record.write(body + b"\n")
        self._send(route)

    def _find(self, method: str) -> dict[str, Any] | None:
        parts = urlsplit(self.path)
        for route in self.routes:
            if route.get("method", "GET") != method or route["path"] != parts.path:
                continue
            if route.get("query", "") not in parts.query or route.get("times", 1) <= 0:
                continue
            # "times": a route that answers only that often, then lets the next match answer (a blip, a flaky stream).
            if "times" in route:
                route["times"] -= 1
            return route
        return None

    def _send(self, route: dict[str, Any] | None) -> None:
        if route is None:
            route = {"status": 404, "body": "not found"}
        body = route.get("body", "").replace("{base}", self.base).encode()
        if "file" in route:
            body = Path(route["file"]).read_bytes()
        body += audio_bytes(route.get("audio", 0))
        if "icy" in route:
            # An old Shoutcast server: no HTTP status line at all.
            self.wfile.write(route["icy"].encode() + body)
            self.close_connection = True
            return
        self.send_response(route.get("status", 200))
        self.send_header("Content-Type", route.get("type", "text/html"))
        self.send_header("Content-Length", str(len(body)))
        for name, value in route.get("headers", {}).items():
            self.send_header(name, value.replace("{base}", self.base))
        self.end_headers()
        self.wfile.write(body)


def make_server(routes: list[dict[str, Any]]) -> ThreadingHTTPServer:
    """Return a server on a free port of 127.0.0.1 that answers from `routes`."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeHandler)
    FakeHandler.routes = routes
    FakeHandler.base = f"http://127.0.0.1:{server.server_address[1]}"
    return server


def main(argv: list[str]) -> int:
    """Serve the routes of argv[1] until the process is stopped."""
    if len(argv) != _ARGUMENT_COUNT:
        sys.stderr.write("usage: fake_station_server.py ROUTES.json\n")
        return 2
    routes = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    server = make_server(routes)
    sys.stdout.write(f"{server.server_address[1]}\n")
    sys.stdout.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
