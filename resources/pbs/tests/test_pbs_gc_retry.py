"""Unit tests for scripts/files/pbs-gc-retry.py. Run with `python3 -m unittest discover -s resources/pbs/tests`.

The PBS API answers are written out in the shape `proxmox-backup-debug api get
--output-format json` prints them. `retry` is run against a fake API and a
temporary state file, so what it starts and what it remembers is what is checked.
"""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "files" / "pbs-gc-retry.py"
spec = importlib.util.spec_from_file_location("pbs_gc_retry", SCRIPT)
gc_retry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gc_retry)

NOW = 1_800_000_000
MIN = 60
FAILED = "garbage collection failed: s3 error: SlowDown (503)"


def job(state=FAILED, ended=NOW - 20 * MIN, upid="UPID:failed", store="offsite"):
    answer = {"store": store, "last-run-endtime": ended, "next-run": NOW + 5 * 86400}
    if state is not None:
        answer.update({"last-run-state": state, "last-run-upid": upid})
    return answer


def entry(**changes):
    return {**gc_retry.new_entry(), "episode_upid": "UPID:failed", **changes}


class Decide(unittest.TestCase):
    def test_a_good_run_needs_no_retry_and_closes_the_episode(self):
        for state in ("OK", "WARNINGS: 2"):
            e = entry(attempts=3, exhausted=True, upids=["UPID:a"])
            self.assertEqual(gc_retry.decide(job(state), e, NOW)[0], "ok")
            self.assertEqual((e["attempts"], e["exhausted"], e["upids"]), (0, False, []))

    def test_a_job_that_never_ran_is_left_alone(self):
        self.assertEqual(gc_retry.decide(job(state=None), entry(), NOW), ("ok", "never run"))

    def test_a_failure_past_its_first_backoff_is_retried(self):
        self.assertEqual(gc_retry.decide(job(), entry(), NOW), ("start", "retry 1 of 5"))

    def test_a_fresh_failure_waits_for_the_first_backoff(self):
        action, _ = gc_retry.decide(job(ended=NOW - 3 * MIN), entry(), NOW)
        self.assertEqual(action, "wait")

    def test_the_backoff_doubles_with_each_attempt(self):
        # Retries are 10, 20, 40, 80 and 160 minutes after the failed run ended.
        for attempts, minutes in enumerate((10, 20, 40, 80, 160)):
            e = entry(attempts=attempts, upids=["UPID:failed"])
            too_soon = job(ended=NOW - minutes * MIN + 1)
            self.assertEqual(gc_retry.decide(too_soon, e, NOW)[0], "wait", minutes)
            due = job(ended=NOW - minutes * MIN)
            self.assertEqual(gc_retry.decide(due, e, NOW)[0], "start", minutes)

    def test_retries_stop_when_the_attempts_are_used(self):
        e = entry(attempts=gc_retry.MAX_ATTEMPTS)
        action, _ = gc_retry.decide(job(ended=NOW - 30 * 86400), e, NOW)
        self.assertEqual(action, "exhausted")
        self.assertTrue(e["exhausted"])

    def test_a_failed_retry_of_ours_stays_in_the_same_episode(self):
        e = entry(attempts=2, upids=["UPID:retry1", "UPID:retry2"])
        gc_retry.decide(job(upid="UPID:retry2", ended=NOW - 86400), e, NOW)
        self.assertEqual(e["attempts"], 2)

    def test_a_failure_we_did_not_start_opens_a_new_episode(self):
        e = entry(attempts=gc_retry.MAX_ATTEMPTS, exhausted=True, upids=["UPID:retry5"])
        action, _ = gc_retry.decide(job(upid="UPID:scheduled", ended=NOW - 20 * MIN), e, NOW)
        self.assertEqual(action, "start")
        self.assertEqual((e["attempts"], e["exhausted"], e["episode_upid"]), (0, False, "UPID:scheduled"))

    def test_no_more_than_the_daily_cap_is_started(self):
        starts = [NOW - 3600 * n for n in range(1, gc_retry.MAX_STARTS_PER_DAY + 1)]
        e = entry(starts=starts)
        self.assertEqual(gc_retry.decide(job(), e, NOW)[0], "capped")

    def test_starts_older_than_a_day_do_not_count(self):
        e = entry(starts=[NOW - 25 * 3600] * gc_retry.MAX_STARTS_PER_DAY)
        self.assertEqual(gc_retry.decide(job(), e, NOW)[0], "start")
        self.assertEqual(e["starts"], [])


class Retry(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state_path = os.path.join(directory.name, "state", "state.json")
        patcher = mock.patch.object(gc_retry, "STATE_PATH", self.state_path)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.started = []

    def run_retry(self, jobs, tasks=(), dry_run=False, start_error=None, now=NOW):
        def fake_api(verb, path, *params, timeout=30):
            if (verb, path) == ("get", "/admin/gc"):
                if isinstance(jobs, Exception):
                    raise jobs
                return jobs
            if (verb, path) == ("get", "/nodes/localhost/tasks"):
                return list(tasks)
            if verb == "create" and path.endswith("/gc"):
                if start_error:
                    raise start_error
                self.started.append(path.split("/")[3])
                return "UPID:retry%d" % len(self.started)
            raise AssertionError((verb, path))

        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(gc_retry, "api", fake_api), contextlib.redirect_stdout(
            out
        ), contextlib.redirect_stderr(err):
            status = gc_retry.retry(now, dry_run)
        return status, out.getvalue() + err.getvalue()

    def state(self):
        with open(self.state_path) as handle:
            return json.load(handle)

    def test_a_failed_gc_is_started_again_and_remembered(self):
        status, log = self.run_retry([job()])
        self.assertEqual((status, self.started), (0, ["offsite"]))
        saved = self.state()["offsite"]
        self.assertEqual((saved["attempts"], saved["upids"], saved["starts"]), (1, ["UPID:retry1"], [NOW]))
        self.assertIn('event=start datastore="offsite" attempts=1', log)

    def test_the_next_run_does_not_start_it_again_while_it_waits(self):
        self.run_retry([job()])
        # Its retry failed 1 minute ago: the next one is 20 minutes after that.
        failed_retry = job(upid="UPID:retry1", ended=NOW + 4 * MIN)
        self.run_retry([failed_retry], now=NOW + 5 * MIN)
        self.assertEqual(self.started, ["offsite"])

    def test_the_retries_follow_the_backoff_then_give_up(self):
        now, ended, upid = NOW, NOW - 20 * MIN, "UPID:failed"
        for attempt in range(1, gc_retry.MAX_ATTEMPTS + 1):
            self.run_retry([job(ended=ended, upid=upid)], now=now)
            self.assertEqual(len(self.started), attempt)
            upid, ended = "UPID:retry%d" % attempt, now + 60
            now = ended + gc_retry.BASE_BACKOFF * 2**attempt
            # The daily cap would stop the later ones; this checks the attempts.
            self.state_cap_off()
        status, log = self.run_retry([job(ended=ended, upid=upid)], now=now)
        self.assertEqual(len(self.started), gc_retry.MAX_ATTEMPTS)
        self.assertTrue(self.state()["offsite"]["exhausted"])
        self.assertIn("event=exhausted", log)
        self.assertEqual(status, 0)

    def state_cap_off(self):
        saved = self.state()
        saved["offsite"]["starts"] = []
        with open(self.state_path, "w") as handle:
            json.dump(saved, handle)

    def test_nothing_is_started_while_any_gc_is_running(self):
        tasks = [{"worker_type": "garbage_collection", "worker_id": "main", "starttime": NOW - 60}]
        status, log = self.run_retry([job()], tasks)
        self.assertEqual((status, self.started), (0, []))
        self.assertIn("event=running", log)
        self.assertEqual(self.state()["offsite"]["attempts"], 0)

    def test_a_finished_gc_task_does_not_block(self):
        tasks = [
            {"worker_type": "garbage_collection", "worker_id": "main", "endtime": NOW - 60},
            {"worker_type": "backup", "worker_id": "main:vm/100", "starttime": NOW - 60},
        ]
        self.run_retry([job()], tasks)
        self.assertEqual(self.started, ["offsite"])

    def test_one_gc_is_started_at_a_time_across_datastores(self):
        self.run_retry([job(store="offsite"), job(store="other", upid="UPID:other")])
        self.assertEqual(self.started, ["offsite"])

    def test_a_good_gc_starts_nothing(self):
        status, log = self.run_retry([job("OK")])
        self.assertEqual((status, self.started), (0, []))
        self.assertIn("event=ok", log)

    def test_dry_run_starts_nothing_and_saves_nothing(self):
        status, log = self.run_retry([job()], dry_run=True)
        self.assertEqual((status, self.started), (0, []))
        self.assertIn("event=would-start", log)
        self.assertFalse(os.path.exists(self.state_path))

    def test_an_unreadable_api_starts_nothing_and_fails_the_run(self):
        status, log = self.run_retry(RuntimeError("proxmox-backup is down"))
        self.assertEqual((status, self.started), (1, []))
        self.assertIn("event=read-failed", log)

    def test_a_start_that_fails_still_uses_an_attempt(self):
        status, log = self.run_retry([job()], start_error=RuntimeError("busy"))
        self.assertEqual(status, 1)
        self.assertEqual(self.state()["offsite"]["attempts"], 1)
        self.assertIn("event=start-failed", log)

    def test_the_last_retry_still_running_is_not_exhausted(self):
        now, ended, upid = NOW, NOW - 20 * MIN, "UPID:failed"
        for attempt in range(1, gc_retry.MAX_ATTEMPTS + 1):
            self.run_retry([job(ended=ended, upid=upid)], now=now)
            upid, ended = "UPID:retry%d" % attempt, now + 60
            now = ended + gc_retry.BASE_BACKOFF * 2**attempt
            self.state_cap_off()
        running = [{"worker_type": "garbage_collection", "worker_id": "offsite", "starttime": now - 60}]
        status, log = self.run_retry([job(ended=ended, upid=upid)], running, now=now)
        self.assertEqual((status, len(self.started)), (0, gc_retry.MAX_ATTEMPTS))
        self.assertFalse(self.state()["offsite"]["exhausted"])
        self.assertNotIn("event=exhausted", log)
        self.assertIn("event=running", log)
        self.run_retry([job(ended=ended, upid=upid)], now=now + 600)
        self.assertTrue(self.state()["offsite"]["exhausted"])

    def test_state_for_a_datastore_that_is_gone_is_pruned(self):
        gc_retry.save_state(
            self.state_path, {"gone": entry(attempts=5, exhausted=True), "offsite": entry(attempts=1)}
        )
        self.run_retry([job(state="OK")])
        self.assertEqual(list(self.state()), ["offsite"])

    def test_success_closes_the_episode(self):
        self.run_retry([job()])
        self.run_retry([job("OK", upid="UPID:retry1", ended=NOW + 600)], now=NOW + 900)
        saved = self.state()["offsite"]
        self.assertEqual((saved["attempts"], saved["exhausted"], saved["upids"]), (0, False, []))


class State(unittest.TestCase):
    def test_a_missing_state_file_is_empty(self):
        self.assertEqual(gc_retry.load_state("/nonexistent/state.json"), {})

    def test_a_corrupt_state_file_is_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "state.json")
            pathlib.Path(path).write_text("{not json")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gc_retry.load_state(path), {})

    def test_save_replaces_the_file_whole(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "new", "state.json")
            gc_retry.save_state(path, {"a": {"attempts": 1}})
            self.assertEqual(gc_retry.load_state(path), {"a": {"attempts": 1}})
            self.assertEqual(os.listdir(os.path.dirname(path)), ["state.json"])


class Lock(unittest.TestCase):
    def test_a_second_copy_does_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = os.path.join(directory, "lock")
            with mock.patch.object(gc_retry, "LOCK_PATH", lock), mock.patch.object(
                gc_retry, "retry", return_value=0
            ) as retry:
                import fcntl

                with open(lock, "w") as held:
                    fcntl.flock(held, fcntl.LOCK_EX)
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(gc_retry.main(["run"]), 0)
                retry.assert_not_called()
                with contextlib.redirect_stdout(io.StringIO()):
                    gc_retry.main(["status"])
                retry.assert_called_once()

    def test_unknown_arguments_print_usage(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gc_retry.main([]), 2)
            self.assertEqual(gc_retry.main(["start"]), 2)


class TaskState(unittest.TestCase):
    def test_ok_and_warnings_are_not_failures(self):
        self.assertTrue(gc_retry.task_ok("OK"))
        self.assertTrue(gc_retry.task_ok("WARNINGS: 3"))
        self.assertFalse(gc_retry.task_ok(FAILED))
        self.assertFalse(gc_retry.task_ok(None))


if __name__ == "__main__":
    unittest.main()
