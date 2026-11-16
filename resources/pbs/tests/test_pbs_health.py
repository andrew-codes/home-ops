"""Unit tests for scripts/files/pbs-health.py. Run with `python3 -m unittest discover -s resources/pbs/tests`.

The PBS API answers are written out here in the shape `proxmox-backup-debug api get
--output-format json` prints them, so a change to the script that stops it reading
a field fails here instead of on the real host.
"""

import importlib.util
import pathlib
import subprocess
import time
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "files" / "pbs-health.py"
spec = importlib.util.spec_from_file_location("pbs_health", SCRIPT)
pbs_health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pbs_health)

NOW = 1_800_000_000
DAY = 86400


def snapshots(*days_ago):
    return [{"backup-time": NOW - d * DAY} for d in days_ago]


def api(overrides=None):
    """A healthy PBS: one datastore `main` with two guests, one failed backup, all jobs fine."""
    answers = {
        "/config/datastore": [{"name": "main", "path": "/mnt/pbs-main/datastore"}],
        "/admin/datastore/main/status": {"total": 10, "used": 4, "avail": 6},
        "/admin/datastore/main/namespace": [],
        "/admin/datastore/main/groups": [
            {"backup-type": "vm", "backup-id": "100", "last-backup": NOW - 3600},
            {"backup-type": "ct", "backup-id": "101", "last-backup": NOW - 2 * DAY},
        ],
        "/nodes/localhost/tasks": [
            {
                "worker_type": "backup",
                "worker_id": "main:vm/100",
                "endtime": NOW - 3600,
                "status": "OK",
            },
            # Older than the one above: the newest task of a guest wins.
            {
                "worker_type": "backup",
                "worker_id": "main:vm/100",
                "endtime": NOW - DAY - 3600,
                "status": "backup failed: connection reset",
            },
            {
                "worker_type": "backup",
                "worker_id": "main:ct/101",
                "endtime": NOW - 2 * DAY,
                "status": "unable to open chunk store at /mnt/pbs/.chunks",
            },
            # Still running: no endtime, no status.
            {"worker_type": "backup", "worker_id": "main:vm/102", "starttime": NOW - 60},
            {"worker_type": "verificationjob", "worker_id": "main:verify-main", "endtime": NOW},
        ],
        "/admin/verify": [
            {
                "id": "verify-main",
                "store": "main",
                "last-run-state": "OK",
                "last-run-endtime": NOW - 5 * DAY,
                "next-run": NOW + 2 * DAY,
            }
        ],
        "/admin/prune": [
            {
                "id": "prune-main",
                "store": "main",
                "last-run-state": "WARNINGS: 2",
                "last-run-endtime": NOW - 3600,
                "next-run": NOW + DAY,
            }
        ],
        "/admin/gc": [
            {
                "store": "main",
                "last-run-state": "garbage collection failed: io error",
                "last-run-endtime": NOW - DAY,
                "next-run": NOW + 6 * DAY,
                "removed-bytes": 1024,
                "pending-bytes": 2048,
            }
        ],
    }
    answers.update(overrides or {})

    def fake_get(path, *params, timeout=30):
        if path == "/admin/datastore/main/snapshots":
            guest = params[params.index("--backup-id") + 1]
            days = {"100": (0, 1, 2, 3, 4, 5), "101": (2, 3), "200": (0, 1, 2)}[guest]
            return snapshots(*days)
        answer = answers[path]
        if isinstance(answer, Exception):
            raise answer
        return answer

    return fake_get


def collect(fake_get, active=True):
    out = pbs_health.Metrics()
    result = subprocess.CompletedProcess([], 0 if active else 3, "", "")
    with mock.patch.object(pbs_health, "api_get", fake_get), mock.patch.object(
        pbs_health, "run", return_value=result
    ):
        pbs_health.collect(out, NOW)
    return out.lines


class TaskState(unittest.TestCase):
    def test_ok_and_warnings_are_not_failures(self):
        self.assertTrue(pbs_health.task_ok("OK"))
        self.assertTrue(pbs_health.task_ok("WARNINGS: 3"))

    def test_errors_and_missing_state_are_failures(self):
        self.assertFalse(pbs_health.task_ok("backup failed: connection reset"))
        self.assertFalse(pbs_health.task_ok("unknown"))
        self.assertFalse(pbs_health.task_ok(None))


class BackupInterval(unittest.TestCase):
    def test_daily_backups(self):
        self.assertEqual(
            pbs_health.backup_interval([NOW - d * DAY for d in range(6)]), DAY
        )

    def test_one_missed_run_does_not_change_the_interval(self):
        days = [0, 1, 2, 4, 5, 6]  # day 3 missed
        self.assertEqual(
            pbs_health.backup_interval([NOW - d * DAY for d in days]), DAY
        )

    def test_weekly_backups(self):
        self.assertEqual(
            pbs_health.backup_interval([NOW - d * 7 * DAY for d in range(4)]), 7 * DAY
        )

    def test_too_few_snapshots_fall_back_to_daily(self):
        self.assertEqual(
            pbs_health.backup_interval([NOW, NOW - 7 * DAY]), pbs_health.DEFAULT_BACKUP_INTERVAL
        )
        self.assertEqual(pbs_health.backup_interval([]), pbs_health.DEFAULT_BACKUP_INTERVAL)


class Collect(unittest.TestCase):
    def test_healthy_host(self):
        lines = collect(api())
        for expected in (
            'pbs_service_up{unit="proxmox-backup"} 1',
            'pbs_service_up{unit="proxmox-backup-proxy"} 1',
            'pbs_datastore_available{datastore="main"} 1',
            'pbs_backup_last_success_timestamp_seconds{backup_id="100",backup_type="vm",datastore="main"} %d'
            % (NOW - 3600),
            'pbs_backup_interval_seconds{backup_id="100",backup_type="vm",datastore="main"} 86400',
            # Two snapshots give one gap: too few to read a schedule from.
            'pbs_backup_interval_seconds{backup_id="101",backup_type="ct",datastore="main"} 86400',
            'pbs_job_last_run_ok{datastore="main",job="verify-main",type="verify"} 1',
            # Warnings are not a failure.
            'pbs_job_last_run_ok{datastore="main",job="prune-main",type="prune"} 1',
            'pbs_gc_removed_bytes{datastore="main"} 1024',
            'pbs_gc_pending_bytes{datastore="main"} 2048',
        ):
            self.assertIn(expected, lines)
        for source in ("services", "datastores", "groups", "tasks", "jobs_verify", "jobs_prune", "jobs_gc"):
            self.assertIn('pbs_health_collect_ok{source="%s"} 1' % source, lines)

    def test_failed_gc_job(self):
        self.assertIn(
            'pbs_job_last_run_ok{datastore="main",type="gc"} 0', collect(api())
        )

    def test_newest_backup_task_of_a_guest_wins(self):
        lines = collect(api())
        self.assertIn(
            'pbs_backup_last_task_ok{backup_id="100",backup_type="vm",datastore="main"} 1', lines
        )
        self.assertIn(
            'pbs_backup_last_task_ok{backup_id="101",backup_type="ct",datastore="main"} 0', lines
        )

    def test_running_and_other_tasks_are_ignored(self):
        lines = collect(api())
        self.assertFalse([line for line in lines if 'backup_id="102"' in line])
        self.assertFalse([line for line in lines if "verify-main" in line and "last_task" in line])

    def test_services_down(self):
        lines = collect(api(), active=False)
        self.assertIn('pbs_service_up{unit="proxmox-backup"} 0', lines)

    def test_unavailable_datastore_is_reported_and_skipped(self):
        fake = api({"/admin/datastore/main/status": RuntimeError("unable to open chunk store")})
        lines = collect(fake)
        self.assertIn('pbs_datastore_available{datastore="main"} 0', lines)
        self.assertFalse([line for line in lines if line.startswith("pbs_backup_last_success")])
        self.assertIn('pbs_health_collect_ok{source="groups"} 1', lines)

    def test_every_datastore_is_reported_and_one_failing_does_not_hide_the_other(self):
        fake = api(
            {
                "/config/datastore": [
                    {"name": "main", "path": "/mnt/pbs-main/datastore"},
                    {"name": "offsite", "path": "/mnt/pbs-cache/offsite", "backend": "type=s3"},
                ],
                "/admin/datastore/offsite/status": RuntimeError("s3 unreachable"),
            }
        )
        lines = collect(fake)
        self.assertIn('pbs_datastore_available{datastore="main"} 1', lines)
        self.assertIn('pbs_datastore_available{datastore="offsite"} 0', lines)
        self.assertIn('pbs_backup_interval_seconds{backup_id="100",backup_type="vm",datastore="main"} 86400', lines)

    def test_hung_datastore_is_unavailable(self):
        fake = api({"/admin/datastore/main/status": subprocess.TimeoutExpired("x", 30)})
        self.assertIn('pbs_datastore_available{datastore="main"} 0', collect(fake))

    def test_a_failing_source_leaves_the_rest(self):
        fake = api({"/admin/verify": RuntimeError("schema changed")})
        lines = collect(fake)
        self.assertIn('pbs_health_collect_ok{source="jobs_verify"} 0', lines)
        self.assertIn('pbs_health_collect_ok{source="jobs_prune"} 1', lines)
        self.assertIn('pbs_datastore_available{datastore="main"} 1', lines)

    def test_no_datastore_config_is_reported(self):
        lines = collect(api({"/config/datastore": RuntimeError("no config")}))
        self.assertIn('pbs_health_collect_ok{source="datastores"} 0', lines)

    def test_namespaces_are_labelled(self):
        base = api({"/admin/datastore/main/namespace": [{"ns": "lab"}]})

        def fake(path, *params, timeout=30):
            if path == "/admin/datastore/main/groups" and "--ns" in params:
                return [{"backup-type": "vm", "backup-id": "200", "last-backup": NOW - 60}]
            return base(path, *params, timeout=timeout)

        lines = collect(fake)
        self.assertIn(
            'pbs_backup_last_success_timestamp_seconds{backup_id="200",backup_type="vm",datastore="main",namespace="lab"} %d'
            % (NOW - 60),
            lines,
        )


class Metrics(unittest.TestCase):
    def test_labels_are_sorted_and_escaped_and_empty_ones_dropped(self):
        out = pbs_health.Metrics()
        out.add("x", 1, b='say "hi"', a="1", c="")
        self.assertEqual(out.lines, ['x{a="1",b="say \\"hi\\""} 1'])


class Run(unittest.TestCase):
    def test_a_command_that_hangs_is_abandoned(self):
        started = time.time()
        with self.assertRaises(subprocess.TimeoutExpired):
            pbs_health.run(["sleep", "30"], timeout=1)
        self.assertLess(time.time() - started, 10)

    def test_output_and_exit_status(self):
        result = pbs_health.run(["sh", "-c", "echo out; echo err >&2; exit 3"])
        self.assertEqual((result.stdout, result.stderr, result.returncode), ("out\n", "err\n", 3))

    def test_api_get_raises_on_failure(self):
        failed = subprocess.CompletedProcess([], 1, "", "unable to open chunk store\n")
        with mock.patch.object(pbs_health, "run", return_value=failed):
            with self.assertRaisesRegex(RuntimeError, "unable to open chunk store"):
                pbs_health.api_get("/admin/datastore/main/status")


if __name__ == "__main__":
    unittest.main()
