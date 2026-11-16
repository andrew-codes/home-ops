"""Reports Proxmox Backup Server task outcomes and backup freshness as Prometheus metrics.

PBS pushes host and datastore usage metrics itself (its InfluxDB metric server),
but those carry no task results. This script fills the gap. It runs on the PBS
host from a systemd timer that resources/pbs installs, and uses only what the
host ships: python3 (standard library only) and proxmox-backup-debug, which calls
the local PBS API as root and works while the proxmox-backup daemon is stopped.

    python3 pbs-health.py print        write the metrics to stdout (a dry run)
    python3 pbs-health.py push <url>   POST them to a VictoriaMetrics /api/v1/import/prometheus URL

A source that fails (an API call, one datastore) is reported as
pbs_health_collect_ok 0 and leaves its other series out, so one bad source does
not hide the rest. The heartbeat is written last, so it only appears when the
run got that far.
"""

from __future__ import annotations

import json
import os
import signal
import statistics
import subprocess
import sys
import time
import urllib.request

# A guest backed up less than three times has no spacing to read, so it is
# assumed to be on a daily schedule.
DEFAULT_BACKUP_INTERVAL = 24 * 3600
# How many of the newest snapshots of a guest the backup spacing is read from.
INTERVAL_SNAPSHOTS = 6
# How far back to look for backup tasks that failed.
TASK_LOOKBACK = 14 * 24 * 3600
# Seconds a single API call may take. A hung NFS mount blocks statfs, and the
# call must not take the whole run (and the heartbeat) with it.
API_TIMEOUT = 30
SERVICES = ("proxmox-backup", "proxmox-backup-proxy")


class Metrics:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def add(self, name: str, value: float, **labels: object) -> None:
        text = ",".join(
            '%s="%s"' % (key, escape(labels[key]))
            for key in sorted(labels)
            if labels[key] not in (None, "")
        )
        self.lines.append("%s%s %s" % (name, "{%s}" % text if text else "", value))


def escape(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def run(argv: list[str], timeout: int = API_TIMEOUT) -> subprocess.CompletedProcess:
    """Run a command, and give up on it after `timeout` seconds.

    A process stuck on a dead NFS mount sleeps uninterruptibly and ignores
    SIGKILL until the mount answers, so a timed-out child is killed and then
    abandoned rather than waited for.
    """
    child = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        try:  # reap it when the kill took effect, and move on when it did not
            child.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        raise
    return subprocess.CompletedProcess(argv, child.returncode, stdout, stderr)


def api_get(path: str, *params: str, timeout: int = API_TIMEOUT):
    argv = ["proxmox-backup-debug", "api", "get", path, "--output-format", "json"]
    result = run(argv + list(params), timeout)
    if result.returncode != 0:
        raise RuntimeError("%s: %s" % (path, result.stderr.strip() or result.returncode))
    return json.loads(result.stdout)


def task_ok(state: object) -> bool:
    """A task state is "OK", "WARNINGS: n" or the error text. Warnings are not failures."""
    return isinstance(state, str) and (state == "OK" or state.startswith("WARNINGS"))


def datastore_names() -> list[str]:
    return [store["name"] for store in api_get("/config/datastore")]


def collect_services(out: Metrics) -> None:
    for unit in SERVICES:
        active = run(["systemctl", "is-active", "--quiet", unit], timeout=10).returncode == 0
        out.add("pbs_service_up", int(active), unit=unit)
    out.add("pbs_health_collect_ok", 1, source="services")


def collect_datastore(out: Metrics, store: str) -> bool:
    """Available means PBS can open the datastore and read its filesystem."""
    try:
        api_get("/admin/datastore/%s/status" % store)
        available = True
    except (RuntimeError, ValueError, subprocess.TimeoutExpired, OSError) as error:
        print("datastore %s: %r" % (store, error), file=sys.stderr)
        available = False
    out.add("pbs_datastore_available", int(available), datastore=store)
    return available


def backup_interval(times: list[int]) -> int:
    """The usual spacing of a guest's backups: the median gap of its newest snapshots.

    PBS does not know the schedule (the backup job lives on the Proxmox VE
    host), so it is read from the backups themselves. The median ignores an
    extra manual backup or one missed run.
    """
    newest = sorted(times, reverse=True)[:INTERVAL_SNAPSHOTS]
    gaps = [a - b for a, b in zip(newest, newest[1:]) if a - b > 0]
    if len(gaps) < 2:
        return DEFAULT_BACKUP_INTERVAL
    return int(statistics.median(gaps))


def snapshot_times(store: str, namespace: str, group: dict) -> list[int]:
    params = [
        "--backup-type", group["backup-type"],
        "--backup-id", group["backup-id"],
    ]
    if namespace:
        params += ["--ns", namespace]
    return [
        snapshot["backup-time"]
        for snapshot in api_get("/admin/datastore/%s/snapshots" % store, *params)
        if "backup-time" in snapshot
    ]


def collect_groups(out: Metrics, store: str) -> None:
    namespaces = [""]
    for item in api_get("/admin/datastore/%s/namespace" % store):
        if item.get("ns") and item["ns"] not in namespaces:
            namespaces.append(item["ns"])
    for namespace in namespaces:
        params = ["--ns", namespace] if namespace else []
        for group in api_get("/admin/datastore/%s/groups" % store, *params):
            last = group.get("last-backup")
            if not last:
                continue
            labels = {
                "datastore": store,
                "namespace": namespace,
                "backup_type": group["backup-type"],
                "backup_id": group["backup-id"],
            }
            out.add("pbs_backup_last_success_timestamp_seconds", last, **labels)
            out.add(
                "pbs_backup_interval_seconds",
                backup_interval(snapshot_times(store, namespace, group)),
                **labels
            )


def collect_backup_tasks(out: Metrics, now: float) -> None:
    """The newest finished backup task of each guest, so a failure clears when a backup succeeds."""
    tasks = api_get(
        "/nodes/localhost/tasks",
        "--typefilter", "backup",
        "--since", str(int(now - TASK_LOOKBACK)),
        "--limit", "0",
    )
    seen: set[str] = set()
    # Newest first. The worker id is "<datastore>:<type>/<id>": it has no namespace.
    for task in tasks:
        if task.get("worker_type") != "backup" or not task.get("endtime"):
            continue
        worker_id = task.get("worker_id") or ""
        if worker_id in seen or ":" not in worker_id or "/" not in worker_id:
            continue
        seen.add(worker_id)
        store, guest = worker_id.split(":", 1)
        backup_type, backup_id = guest.split("/", 1)
        labels = {"datastore": store, "backup_type": backup_type, "backup_id": backup_id}
        out.add("pbs_backup_last_task_ok", int(task_ok(task.get("status"))), **labels)
        out.add("pbs_backup_last_task_end_timestamp_seconds", task["endtime"], **labels)


def add_job(out: Metrics, kind: str, job: dict) -> None:
    labels = {"type": kind, "datastore": job.get("store"), "job": job.get("id")}
    state = job.get("last-run-state")
    if state is not None:  # a job that has not run yet has no state
        out.add("pbs_job_last_run_ok", int(task_ok(state)), **labels)
    if job.get("last-run-endtime"):
        out.add("pbs_job_last_run_end_timestamp_seconds", job["last-run-endtime"], **labels)
    if job.get("next-run"):
        out.add("pbs_job_next_run_timestamp_seconds", job["next-run"], **labels)


def collect_jobs(out: Metrics) -> None:
    for kind, path in (("verify", "/admin/verify"), ("prune", "/admin/prune"), ("gc", "/admin/gc")):
        try:
            for job in api_get(path):
                add_job(out, kind, job)
                if kind == "gc":
                    for field, metric in (
                        ("removed-bytes", "pbs_gc_removed_bytes"),
                        ("pending-bytes", "pbs_gc_pending_bytes"),
                    ):
                        if job.get(field) is not None:
                            out.add(metric, job[field], datastore=job.get("store"))
            out.add("pbs_health_collect_ok", 1, source="jobs_" + kind)
        except Exception as error:  # a schema change must not stop the rest
            print("%s: %r" % (path, error), file=sys.stderr)
            out.add("pbs_health_collect_ok", 0, source="jobs_" + kind)


def collect(out: Metrics, now: float) -> None:
    try:
        collect_services(out)
    except Exception as error:
        print("services: %r" % (error,), file=sys.stderr)
        out.add("pbs_health_collect_ok", 0, source="services")
    try:
        stores = datastore_names()
        out.add("pbs_health_collect_ok", 1, source="datastores")
    except Exception as error:
        print("datastores: %r" % (error,), file=sys.stderr)
        out.add("pbs_health_collect_ok", 0, source="datastores")
        stores = []
    # A datastore that cannot be opened has no groups to list, and is already
    # reported by pbs_datastore_available.
    available = [store for store in stores if collect_datastore(out, store)]
    groups_ok = 1
    for store in available:
        try:
            collect_groups(out, store)
        except Exception as error:
            print("groups %s: %r" % (store, error), file=sys.stderr)
            groups_ok = 0
    out.add("pbs_health_collect_ok", groups_ok, source="groups")
    try:
        collect_backup_tasks(out, now)
        out.add("pbs_health_collect_ok", 1, source="tasks")
    except Exception as error:
        print("tasks: %r" % (error,), file=sys.stderr)
        out.add("pbs_health_collect_ok", 0, source="tasks")
    collect_jobs(out)


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("print", "push") or (argv[0] == "push" and len(argv) != 2):
        print(__doc__, file=sys.stderr)
        return 2
    started = time.time()
    out = Metrics()
    collect(out, started)
    out.add("pbs_health_collect_duration_seconds", round(time.time() - started, 3))
    out.add("pbs_health_push_timestamp_seconds", int(time.time()))
    body = "\n".join(out.lines) + "\n"
    if argv[0] == "print":
        sys.stdout.write(body)
        return 0
    request = urllib.request.Request(argv[1], data=body.encode(), method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
