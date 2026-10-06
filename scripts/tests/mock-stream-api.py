#!/usr/bin/env python3
"""A stand-in for the slice of the Cloudflare Stream API that
scripts/bin/remodel-gallery-publish-video.sh uses, for tests only.

It speaks tus (create, HEAD, PATCH), the video details update, and the video
details read. It checks the bearer token on API calls, enforces tus offsets and
chunk rules, and appends one JSON line per request to the log file so a test can
assert what was sent (including that the token never went anywhere unexpected).

Usage: mock-stream-api.py PORT STATE_DIR TOKEN [fail-first-patch] [partial-first-patch] [encode-error] [evil-location]
Writes STATE_DIR/ready once it is listening. Uploaded bytes land in STATE_DIR/<uid>.bin
and the request log in STATE_DIR/requests.jsonl.
"""
import base64
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
STATE = sys.argv[2]
TOKEN = sys.argv[3]
FLAGS = set(sys.argv[4:])
ACCOUNT = "acct123"
CUSTOMER = "customer-mock.cloudflarestream.com"
lock = threading.Lock()
uploads = {}   # uid -> {"length": int, "offset": int, "meta": {}}
polls = {}     # uid -> number of GET details
failed_once = [False]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def record(self, extra=None):
        entry = {"method": self.command, "path": self.path, "auth": self.headers.get("Authorization")}
        entry.update(extra or {})
        with lock, open(os.path.join(STATE, "requests.jsonl"), "a") as f:
            f.write(json.dumps(entry) + "\n")

    def send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, code, obj):
        self.send(code, json.dumps(obj).encode(), {"Content-Type": "application/json"})

    def authed(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_POST(self):
        body = self.read_body()
        m = re.fullmatch(r"/accounts/%s/stream" % ACCOUNT, self.path)
        if m:
            self.record({"tus": self.headers.get("Tus-Resumable"), "length": self.headers.get("Upload-Length"),
                         "metadata": self.headers.get("Upload-Metadata")})
            if not self.authed():
                return self.json(401, {"success": False, "errors": [{"code": 10000, "message": "Authentication error"}]})
            uid = "%032x" % (len(uploads) + 1)
            meta = {}
            for pair in (self.headers.get("Upload-Metadata") or "").split(","):
                if pair.strip():
                    k, _, v = pair.strip().partition(" ")
                    meta[k] = base64.b64decode(v).decode()
            uploads[uid] = {"length": int(self.headers["Upload-Length"]), "offset": 0, "meta": meta}
            open(os.path.join(STATE, uid + ".bin"), "wb").close()
            loc_host = "evil.example.net" if "evil-location" in FLAGS else "127.0.0.1"
            return self.send(201, b"", {"Location": "http://%s:%d/upload/%s" % (loc_host, PORT, uid),
                                        "stream-media-id": uid, "Tus-Resumable": "1.0.0"})
        m = re.fullmatch(r"/accounts/%s/stream/([0-9a-f]+)" % ACCOUNT, self.path)
        if m:
            self.record({"body": json.loads(body or b"{}")})
            if not self.authed():
                return self.json(401, {"success": False})
            if m.group(1) not in uploads:
                return self.json(404, {"success": False})
            uploads[m.group(1)]["details"] = json.loads(body)
            return self.json(200, {"success": True, "result": self.details(m.group(1))})
        self.json(404, {"success": False})

    def details(self, uid):
        n = polls.get(uid, 0)
        state = "inprogress" if n < 1 else ("error" if "encode-error" in FLAGS else "ready")
        status = {"state": state}
        if state == "error":
            status["errorReasonText"] = "mock: unsupported codec"
        return {"uid": uid, "thumbnail": "https://%s/%s/thumbnails/thumbnail.jpg" % (CUSTOMER, uid),
                "preview": "https://%s/%s/watch" % (CUSTOMER, uid), "status": status,
                "meta": uploads[uid].get("details", {}).get("meta", {}),
                "allowedOrigins": uploads[uid].get("details", {}).get("allowedOrigins", [])}

    def do_GET(self):
        m = re.fullmatch(r"/accounts/%s/stream/([0-9a-f]+)" % ACCOUNT, self.path)
        self.record()
        if not m:
            return self.json(404, {"success": False})
        if not self.authed():
            return self.json(401, {"success": False})
        if m.group(1) not in uploads:
            return self.json(404, {"success": False})
        uid = m.group(1)
        out = self.details(uid)
        polls[uid] = polls.get(uid, 0) + 1
        self.json(200, {"success": True, "result": out})

    def do_HEAD(self):
        m = re.fullmatch(r"/upload/([0-9a-f]+)", self.path)
        self.record()
        if not m or m.group(1) not in uploads:
            return self.send(404)
        self.send(200, b"", {"Upload-Offset": str(uploads[m.group(1)]["offset"]),
                             "Upload-Length": str(uploads[m.group(1)]["length"]), "Tus-Resumable": "1.0.0"})

    def do_PATCH(self):
        m = re.fullmatch(r"/upload/([0-9a-f]+)", self.path)
        body = self.read_body()
        up = uploads.get(m.group(1)) if m else None
        self.record({"offset": self.headers.get("Upload-Offset"), "bytes": len(body),
                     "type": self.headers.get("Content-Type")})
        if up is None:
            return self.send(404)
        if "fail-first-patch" in FLAGS and not failed_once[0] and up["offset"] > 0:
            failed_once[0] = True
            return self.send(500)
        if "partial-first-patch" in FLAGS and not failed_once[0] and up["offset"] > 0:
            failed_once[0] = True
            with open(os.path.join(STATE, m.group(1) + ".bin"), "ab") as f:
                f.write(body[:100000])
            up["offset"] += 100000
            return self.send(500)
        if int(self.headers.get("Upload-Offset", -1)) != up["offset"]:
            return self.send(409)
        last = up["offset"] + len(body) == up["length"]
        if not last and len(body) % 262144:
            return self.send(400)
        with open(os.path.join(STATE, m.group(1) + ".bin"), "ab") as f:
            f.write(body)
        up["offset"] += len(body)
        self.send(204, b"", {"Upload-Offset": str(up["offset"]), "Tus-Resumable": "1.0.0"})


server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
open(os.path.join(STATE, "ready"), "w").close()
server.serve_forever()
