"""Tests for the vote collector. Run: python3 -m unittest discover -s . -p 'test_*.py'"""

import http.client
import json
import os
import tempfile
import threading
import unittest

import collector

TOKEN = "t" * 32
BALLOT = "3f2b8c1e-9d4a-4e6f-8a1b-0c2d3e4f5a6b"
OTHER_BALLOT = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.votes_file = os.path.join(self.tmp.name, "votes.jsonl")
        self.start()

    def start(self, **limits):
        self.server = collector.build_server(
            collector.VoteStore(self.votes_file), TOKEN, "127.0.0.1", 0, **limits
        )
        self.port = self.server.server_address[1]
        threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
        ).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
            headers = {"Content-Type": "application/json", **(headers or {})}
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        data = response.read().decode("utf-8")
        conn.close()
        return response.status, dict(response.getheaders()), data

    def vote(self, **overrides):
        ballot = {"ballotId": BALLOT, "picks": ["elmosoft_93129", "samba-medal"]}
        ballot.update(overrides)
        return self.request("POST", "/api/votes", ballot)

    def stored_lines(self):
        with open(self.votes_file, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle]

    # --- submit ---

    def test_accepts_a_ballot_and_stores_a_json_line(self):
        status, _, body = self.vote(name="Sam", comment="Love the blue one")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True, "updated": False})
        (line,) = self.stored_lines()
        self.assertEqual(line["picks"], ["elmosoft_93129", "samba-medal"])
        self.assertEqual(line["name"], "Sam")
        self.assertIn("receivedAt", line)
        self.assertEqual(
            set(line), {"ballotId", "picks", "name", "comment", "receivedAt"}
        )

    def test_revising_a_ballot_reports_updated_and_replaces_it(self):
        self.vote(picks=["a"])
        status, _, body = self.vote(picks=["b", "c"], comment="changed my mind")
        self.assertEqual(json.loads(body), {"ok": True, "updated": True})
        self.assertEqual(len(self.stored_lines()), 2)
        results = json.loads(self.request("GET", "/api/results?token=" + TOKEN)[2])
        self.assertEqual(results["ballots"], 1)
        self.assertEqual(results["perCouch"], {"b": 1, "c": 1})
        detail = results["ballotsDetail"][0]
        self.assertEqual(detail["comment"], "changed my mind")
        self.assertLessEqual(detail["firstSeen"], detail["lastUpdated"])

    def test_ballot_id_case_does_not_create_a_second_ballot(self):
        self.vote()
        self.vote(ballotId=BALLOT.upper())
        results = json.loads(self.request("GET", "/api/results?token=" + TOKEN)[2])
        self.assertEqual(results["ballots"], 1)

    def test_duplicate_picks_count_once(self):
        self.vote(picks=["a", "a", "b"])
        results = json.loads(self.request("GET", "/api/results?token=" + TOKEN)[2])
        self.assertEqual(results["perCouch"], {"a": 1, "b": 1})

    def test_rejects_invalid_ballots(self):
        bad = [
            {"ballotId": "not-a-uuid"},
            {"ballotId": "3f2b8c1e-9d4a-1e6f-8a1b-0c2d3e4f5a6b"},  # not v4
            {"picks": []},
            {"picks": ["Has Caps"]},
            {"picks": ["../etc/passwd"]},
            {"picks": ["a" * 65]},
            {"picks": ["a%d" % i for i in range(81)]},
            {"picks": "elmosoft_93129"},
            {"picks": [1]},
            {"name": "n" * 61},
            {"comment": "c" * 2001},
            {"name": 5},
            {"comment": "bell\x07"},
            {"surprise": "field"},
        ]
        for overrides in bad:
            with self.subTest(overrides=overrides):
                status, _, body = self.vote(**overrides)
                self.assertEqual(status, 400)
                self.assertFalse(json.loads(body)["ok"])
        self.assertFalse(os.path.exists(self.votes_file))

    def test_limits_are_inclusive(self):
        status, *_ = self.vote(
            name="n" * 60,
            comment="c" * 2000,
            picks=["a%d" % i for i in range(80)],
        )
        self.assertEqual(status, 200)

    def test_missing_required_fields(self):
        self.assertEqual(self.request("POST", "/api/votes", {})[0], 400)
        self.assertEqual(self.request("POST", "/api/votes", [])[0], 400)

    def test_rejects_bad_json_and_content_type(self):
        status, *_ = self.request(
            "POST", "/api/votes", "{nope", {"Content-Type": "application/json"}
        )
        self.assertEqual(status, 400)
        status, *_ = self.request(
            "POST", "/api/votes", json.dumps({"ballotId": BALLOT, "picks": ["a"]}),
            {"Content-Type": "text/plain"},
        )
        self.assertEqual(status, 400)

    def test_accepts_content_type_with_charset(self):
        status, *_ = self.request(
            "POST",
            "/api/votes",
            json.dumps({"ballotId": BALLOT, "picks": ["a"]}),
            {"Content-Type": "application/json; charset=utf-8"},
        )
        self.assertEqual(status, 200)

    def test_oversize_body_is_413(self):
        status, *_ = self.vote(comment="x" * 20000)
        self.assertEqual(status, 413)
        self.assertFalse(os.path.exists(self.votes_file))

    def test_rate_limit_per_client_with_forwarded_for(self):
        self.tearDown_server_only()
        self.start(post_per_minute=3, global_per_minute=100)
        headers = {"X-Forwarded-For": "10.0.0.1"}
        codes = [
            self.request(
                "POST", "/api/votes", {"ballotId": BALLOT, "picks": ["a"]}, headers
            )[0]
            for _ in range(5)
        ]
        self.assertEqual(codes, [200, 200, 200, 429, 429])
        # A different client behind the proxy is unaffected.
        other = self.request(
            "POST",
            "/api/votes",
            {"ballotId": OTHER_BALLOT, "picks": ["a"]},
            {"X-Forwarded-For": "10.0.0.2"},
        )
        self.assertEqual(other[0], 200)

    def test_global_rate_limit(self):
        self.tearDown_server_only()
        self.start(post_per_minute=100, global_per_minute=2)
        codes = [
            self.request(
                "POST",
                "/api/votes",
                {"ballotId": BALLOT, "picks": ["a"]},
                {"X-Forwarded-For": "10.0.0.%d" % i},
            )[0]
            for i in range(4)
        ]
        self.assertEqual(codes, [200, 200, 429, 429])

    def tearDown_server_only(self):
        self.server.shutdown()
        self.server.server_close()

    def test_unknown_routes_and_methods(self):
        self.assertEqual(self.request("GET", "/api/votes")[0], 404)
        self.assertEqual(self.request("POST", "/api/other", {})[0], 404)
        self.assertEqual(self.request("PUT", "/api/votes", {})[0], 405)

    # --- results ---

    def test_results_require_the_token(self):
        self.vote(comment="private thoughts")
        for path in ("/api/results", "/results"):
            for query in ("", "?token=wrong", "?token=", "?token=" + "t" * 31):
                with self.subTest(path=path, query=query):
                    status, _, body = self.request("GET", path + query)
                    self.assertEqual(status, 401)
                    self.assertNotIn("private thoughts", body)
                    self.assertNotIn(BALLOT, body)

    def test_token_with_non_ascii_does_not_crash(self):
        status, *_ = self.request("GET", "/api/results?token=%C3%A9%C3%A9")
        self.assertEqual(status, 401)

    def test_repeated_wrong_tokens_are_throttled(self):
        codes = [self.request("GET", "/api/results?token=nope")[0] for _ in range(12)]
        self.assertEqual(codes[:10], [401] * 10)
        self.assertEqual(codes[10:], [429, 429])
        # A correct token is never throttled.
        self.assertEqual(self.request("GET", "/api/results?token=" + TOKEN)[0], 200)

    def test_json_results_aggregate_latest_per_ballot(self):
        self.vote(ballotId=BALLOT, picks=["a", "b"], name="Sam")
        self.vote(ballotId=OTHER_BALLOT, picks=["b", "c"])
        status, _, body = self.request("GET", "/api/results?token=" + TOKEN)
        self.assertEqual(status, 200)
        results = json.loads(body)
        self.assertEqual(results["ballots"], 2)
        self.assertEqual(results["perCouch"], {"a": 1, "b": 2, "c": 1})
        self.assertEqual(
            set(results["ballotsDetail"][0]),
            {"ballotId", "name", "comment", "picks", "firstSeen", "lastUpdated"},
        )

    def test_empty_store_has_empty_results(self):
        results = json.loads(self.request("GET", "/api/results?token=" + TOKEN)[2])
        self.assertEqual(results, {"ballots": 0, "perCouch": {}, "ballotsDetail": []})
        self.assertEqual(self.request("GET", "/results?token=" + TOKEN)[0], 200)

    def test_corrupt_lines_are_skipped(self):
        self.vote()
        with open(self.votes_file, "a", encoding="utf-8") as handle:
            handle.write('{"ballotId": 5}\nnot json\n[1]\n{"torn":')
        results = json.loads(self.request("GET", "/api/results?token=" + TOKEN)[2])
        self.assertEqual(results["ballots"], 1)

    def test_results_page_escapes_user_text_and_sets_csp(self):
        xss = '<script>alert("x")</script><img src=x onerror=alert(1)>'
        self.vote(name=xss, comment=xss, picks=["elmosoft_93129"])
        status, headers, body = self.request("GET", "/results?token=" + TOKEN)
        self.assertEqual(status, 200)
        self.assertNotIn("<script>", body)
        self.assertNotIn("<img", body)
        self.assertIn("&lt;script&gt;", body)
        self.assertIn("elmosoft_93129", body)
        csp = headers["Content-Security-Policy"]
        self.assertIn("default-src 'none'", csp)
        self.assertNotIn("script-src", csp.replace("default-src", ""))
        self.assertNotIn("unsafe-inline", csp)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        self.assertTrue(headers["Content-Type"].startswith("text/html"))

    def test_results_page_ranks_by_votes(self):
        self.vote(ballotId=BALLOT, picks=["low", "high"])
        self.vote(ballotId=OTHER_BALLOT, picks=["high"])
        body = self.request("GET", "/results?token=" + TOKEN)[2]
        self.assertLess(body.index("<td>high</td>"), body.index("<td>low</td>"))

    def test_nothing_about_requests_is_logged(self):
        import contextlib
        import io

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.vote(comment="very secret comment")
            self.request("GET", "/api/results?token=" + TOKEN)
        self.assertEqual(out.getvalue() + err.getvalue(), "")

    def test_healthz_is_open(self):
        self.assertEqual(self.request("GET", "/healthz")[0], 200)

    def test_store_full_is_503(self):
        original = collector.MAX_STORE_BYTES
        collector.MAX_STORE_BYTES = 10
        try:
            self.assertEqual(self.vote()[0], 503)
        finally:
            collector.MAX_STORE_BYTES = original

    def test_forwarded_for_is_ignored_from_non_loopback_peers(self):
        # The handler trusts the header only when the peer is loopback; the
        # unit under test is the decision, so call it directly.
        handler = collector.make_handler(None, TOKEN, None, None, None)
        stub = type("H", (), {})()
        stub.client_address = ("10.1.2.3", 1)
        stub.headers = type("Hd", (), {"get": lambda s, k, d="": "6.6.6.6"})()
        self.assertEqual(handler.client_ip(stub), "10.1.2.3")
        stub.client_address = ("127.0.0.1", 1)
        self.assertEqual(handler.client_ip(stub), "6.6.6.6")


class RateLimiterTest(unittest.TestCase):
    def test_window_slides(self):
        now = [0.0]
        limiter = collector.RateLimiter(2, 60, clock=lambda: now[0])
        self.assertTrue(limiter.allow("a"))
        self.assertTrue(limiter.allow("a"))
        self.assertFalse(limiter.allow("a"))
        self.assertTrue(limiter.allow("b"))
        now[0] = 61.0
        self.assertTrue(limiter.allow("a"))


class MainTest(unittest.TestCase):
    def test_refuses_to_start_without_a_strong_token(self):
        for token in ("", "short"):
            os.environ["RESULTS_TOKEN"] = token
            with self.assertRaises(SystemExit):
                collector.main()
        del os.environ["RESULTS_TOKEN"]


if __name__ == "__main__":
    unittest.main()
