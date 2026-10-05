#!/usr/bin/env python3
"""Couch colors vote collector.

A small, dependency-free HTTP service that runs as a sidecar next to the page
server. It accepts ballots, appends them to a JSON-lines file, and serves the
owner-only results.

POST /api/votes           submit or revise a ballot
GET  /api/results?token=  results as JSON (owner only)
GET  /results?token=      results as an HTML page (owner only)

Privacy: no IP addresses, user agents or request paths are ever stored or
logged, and vote contents are never logged.
"""

import hmac
import html
import json
import os
import re
import secrets
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MAX_BODY_BYTES = 16 * 1024
MAX_PICKS = 80
MAX_NAME_CHARS = 60
MAX_COMMENT_CHARS = 2000
MAX_STORE_BYTES = 64 * 1024 * 1024
MIN_TOKEN_CHARS = 24
ALLOWED_FIELDS = {"ballotId", "picks", "name", "comment"}

BALLOT_ID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
PICK_RE = re.compile(r"^[a-z0-9_-]{1,64}$")
# C0 controls other than tab, newline and carriage return.
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class ValidationError(Exception):
    pass


def validate_ballot(payload):
    """Return a normalised ballot dict, or raise ValidationError."""
    if not isinstance(payload, dict):
        raise ValidationError("body must be a JSON object")
    unknown = set(payload) - ALLOWED_FIELDS
    if unknown:
        raise ValidationError("unknown field")

    ballot_id = payload.get("ballotId")
    if not isinstance(ballot_id, str) or not BALLOT_ID_RE.match(ballot_id.lower()):
        raise ValidationError("ballotId must be a uuid v4")

    picks = payload.get("picks")
    if not isinstance(picks, list) or not 1 <= len(picks) <= MAX_PICKS:
        raise ValidationError("picks must have 1 to %d entries" % MAX_PICKS)
    for pick in picks:
        if not isinstance(pick, str) or not PICK_RE.match(pick):
            raise ValidationError("invalid pick id")

    texts = {}
    for field, limit in (("name", MAX_NAME_CHARS), ("comment", MAX_COMMENT_CHARS)):
        value = payload.get(field)
        if value is None:
            value = ""
        if not isinstance(value, str):
            raise ValidationError("%s must be a string" % field)
        value = value.strip()
        if len(value) > limit:
            raise ValidationError("%s is too long" % field)
        if CONTROL_RE.search(value):
            raise ValidationError("%s has control characters" % field)
        texts[field] = value

    return {
        "ballotId": ballot_id.lower(),
        # A repeated pick must not count twice.
        "picks": list(dict.fromkeys(picks)),
        "name": texts["name"],
        "comment": texts["comment"],
    }


class StoreFull(Exception):
    pass


class VoteStore:
    """Append-only JSON-lines file; aggregation happens on read."""

    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()

    def append(self, ballot):
        """Persist a ballot. Returns True when the ballotId already had one."""
        record = dict(ballot)
        record["receivedAt"] = datetime.now(timezone.utc).isoformat(
            timespec="seconds"
        )
        line = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
        with self._lock:
            updated = any(b["ballotId"] == ballot["ballotId"] for b in self._read())
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                if os.fstat(fd).st_size + len(line) > MAX_STORE_BYTES:
                    raise StoreFull()
                os.write(fd, line)
                os.fsync(fd)
            finally:
                os.close(fd)
        return updated

    def _read(self):
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                lines = handle.readlines()
        except FileNotFoundError:
            return
        for line in lines:
            try:
                record = json.loads(line)
                if isinstance(record, dict) and isinstance(record["ballotId"], str):
                    yield record
            except (ValueError, KeyError):
                # A torn or hand-edited line must not take results down.
                continue

    def results(self):
        """Latest submission per ballotId, in file order."""
        ballots = {}
        for record in self._read():
            existing = ballots.get(record["ballotId"])
            first_seen = existing["firstSeen"] if existing else record.get("receivedAt")
            ballots[record["ballotId"]] = {
                "ballotId": record["ballotId"],
                "name": record.get("name", ""),
                "comment": record.get("comment", ""),
                "picks": record.get("picks", []),
                "firstSeen": first_seen,
                "lastUpdated": record.get("receivedAt"),
            }
        detail = list(ballots.values())
        per_couch = {}
        for ballot in detail:
            for pick in ballot["picks"]:
                per_couch[pick] = per_couch.get(pick, 0) + 1
        return {"ballots": len(detail), "perCouch": per_couch, "ballotsDetail": detail}


class RateLimiter:
    """In-memory sliding window, keyed by client."""

    MAX_KEYS = 10000

    def __init__(self, limit, window_seconds, clock=time.monotonic):
        self.limit = limit
        self.window = window_seconds
        self.clock = clock
        self._hits = {}
        self._lock = threading.Lock()

    def allow(self, key):
        now = self.clock()
        with self._lock:
            if len(self._hits) >= self.MAX_KEYS and key not in self._hits:
                self._hits = {
                    k: h for k, h in self._hits.items() if h and h[-1] > now - self.window
                }
                if len(self._hits) >= self.MAX_KEYS:
                    return False
            hits = self._hits.setdefault(key, deque())
            while hits and hits[0] <= now - self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True


def token_matches(supplied, expected):
    return hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8"))


def render_results_page(results, nonce):
    esc = lambda value: html.escape(str(value), quote=True)
    total = results["ballots"]
    ranked = sorted(results["perCouch"].items(), key=lambda kv: (-kv[1], kv[0]))
    rows = "".join(
        "<tr><td>%d</td><td>%s</td><td>%d</td>"
        '<td><meter min="0" max="%d" value="%d"></meter></td></tr>'
        % (rank, esc(couch), votes, max(total, 1), votes)
        for rank, (couch, votes) in enumerate(ranked, 1)
    )
    comments = "".join(
        "<li><p><strong>%s</strong> <small>%s</small></p>"
        "<p class=\"c\">%s</p><p><small>Picks: %s</small></p></li>"
        % (
            esc(b["name"] or "Anonymous"),
            esc(b["lastUpdated"] or ""),
            esc(b["comment"]),
            esc(", ".join(b["picks"])),
        )
        for b in reversed(results["ballotsDetail"])
        if b["comment"]
    )
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="robots" content="noindex">'
        "<title>Couch color votes</title>"
        '<style nonce="%s">'
        "body{font:16px/1.5 system-ui,sans-serif;max-width:56rem;margin:2rem auto;padding:0 1rem}"
        "table{border-collapse:collapse;width:100%%}"
        "th,td{text-align:left;padding:.3rem .6rem;border-bottom:1px solid #8884}"
        "meter{width:12rem}ul{padding:0;list-style:none}"
        "li{border:1px solid #8886;border-radius:.5rem;padding:.2rem 1rem;margin:.6rem 0}"
        ".c{white-space:pre-wrap;overflow-wrap:anywhere}"
        "</style></head><body><h1>Couch color votes</h1>"
        "<p>%d ballot(s). Latest submission per browser counted.</p>"
        "<h2>Ranking</h2><table><thead><tr><th>#</th><th>Couch</th><th>Votes</th>"
        "<th></th></tr></thead><tbody>%s</tbody></table>"
        "<h2>Comments</h2><ul>%s</ul></body></html>"
    ) % (nonce, total, rows, comments or "<li>No comments yet.</li>")


def make_handler(store, token, post_limiter, global_limiter, auth_limiter):
    class Handler(BaseHTTPRequestHandler):
        server_version = "couch-votes"
        sys_version = ""
        protocol_version = "HTTP/1.1"
        timeout = 10

        # Request lines carry the results token and ballots carry user text,
        # so nothing about requests is ever logged.
        def log_message(self, *args):
            pass

        def client_ip(self):
            peer = self.client_address[0]
            if peer in ("127.0.0.1", "::1"):
                # Only the in-pod reverse proxy connects from loopback, and it
                # sets this header itself; take its (last) entry.
                forwarded = self.headers.get("X-Forwarded-For", "")
                if forwarded:
                    return forwarded.split(",")[-1].strip()
            return peer

        def send(self, status, body, content_type, extra=None):
            payload = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            for name, value in (extra or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(payload)

        def send_json(self, status, obj, extra=None):
            self.send(status, json.dumps(obj), "application/json; charset=utf-8", extra)

        def fail(self, status, reason, extra=None):
            self.send_json(status, {"ok": False, "error": reason}, extra)

        def do_GET(self):
            url = urlsplit(self.path)
            if url.path == "/healthz":
                return self.send(200, "ok", "text/plain; charset=utf-8")
            if url.path not in ("/api/results", "/results"):
                return self.fail(404, "not found")
            ip = self.client_ip()
            if not self.authorised(url, ip):
                return
            results = store.results()
            if url.path == "/api/results":
                return self.send_json(200, results)
            nonce = secrets.token_urlsafe(16)
            csp = (
                "default-src 'none'; style-src 'nonce-%s'; base-uri 'none'; "
                "form-action 'none'; frame-ancestors 'none'" % nonce
            )
            self.send(
                200,
                render_results_page(results, nonce),
                "text/html; charset=utf-8",
                {"Content-Security-Policy": csp},
            )

        def authorised(self, url, ip):
            supplied = parse_qs(url.query).get("token", [""])[0]
            if supplied and token_matches(supplied, token):
                return True
            if not auth_limiter.allow(ip):
                self.fail(429, "too many requests", {"Retry-After": "60"})
            else:
                self.fail(401, "unauthorized")
            return False

        def do_POST(self):
            if urlsplit(self.path).path != "/api/votes":
                self.close_connection = True
                return self.fail(404, "not found")
            # Charge the attempt before reading anything from the client.
            if not (
                post_limiter.allow(self.client_ip()) and global_limiter.allow("*")
            ):
                self.close_connection = True
                return self.fail(429, "too many requests", {"Retry-After": "60"})
            if self.headers.get("Transfer-Encoding"):
                self.close_connection = True
                return self.fail(400, "chunked bodies are not accepted")
            length = self.headers.get("Content-Length", "")
            if not length.isdigit():
                self.close_connection = True
                return self.fail(400, "content-length required")
            if int(length) > MAX_BODY_BYTES:
                self.close_connection = True
                return self.fail(413, "body too large")
            media_type = self.headers.get("Content-Type", "").split(";")[0].strip()
            body = self.rfile.read(int(length))
            if media_type.lower() != "application/json":
                return self.fail(400, "content-type must be application/json")
            try:
                ballot = validate_ballot(json.loads(body.decode("utf-8")))
            except (ValueError, ValidationError) as error:
                reason = str(error) if isinstance(error, ValidationError) else "invalid json"
                return self.fail(400, reason)
            try:
                updated = store.append(ballot)
            except StoreFull:
                return self.fail(503, "storage full")
            except OSError:
                print("vote store write failed", file=sys.stderr, flush=True)
                return self.fail(503, "storage unavailable")
            self.send_json(200, {"ok": True, "updated": updated})

        def _method_not_allowed(self):
            self.fail(405, "method not allowed")

        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _method_not_allowed

    return Handler


def build_server(store, token, host, port, post_per_minute=20, global_per_minute=200):
    handler = make_handler(
        store,
        token,
        RateLimiter(post_per_minute, 60),
        RateLimiter(global_per_minute, 60),
        RateLimiter(10, 60),
    )
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def main():
    token = os.environ.get("RESULTS_TOKEN", "")
    if len(token) < MIN_TOKEN_CHARS:
        sys.exit("RESULTS_TOKEN must be set to at least %d characters" % MIN_TOKEN_CHARS)
    votes_file = os.environ.get("VOTES_FILE", "/votes/votes.jsonl")
    server = build_server(
        VoteStore(votes_file),
        token,
        os.environ.get("BIND", "0.0.0.0"),
        int(os.environ.get("PORT", "8081")),
        int(os.environ.get("POST_PER_MINUTE", "20")),
        int(os.environ.get("GLOBAL_POST_PER_MINUTE", "200")),
    )
    print("vote collector listening", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
