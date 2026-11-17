"""Reports ZFS pool, vdev, SMART and scheduled task health from a TrueNAS host as Prometheus metrics.

It runs on the NAS as a TrueNAS cron job that apps/truenas installs, and uses
only what the appliance ships: python3 (standard library only), midclt and
smartctl. Pool and disk state come from the middleware (pool.query,
boot.get_state, disk.query), SMART from `smartctl -j`, because TrueNAS 25.10
removed its SMART API. Cloud sync, replication, snapshot and rsync tasks come
from their middleware queries, with the middleware's recent job history.

    python3 truenas-health.py print         write the metrics to stdout (a dry run)
    python3 truenas-health.py push <url>    POST them to a VictoriaMetrics /api/v1/import/prometheus URL

A source that fails (a middleware call, one disk) is reported as
truenas_health_collect_ok 0 and leaves its other series out, so one bad disk
does not hide the rest.
"""

from __future__ import annotations

import datetime
import json
import subprocess
import sys
import time
import urllib.request

# Attribute id -> metric name for ATA disks. A disk that does not report an
# attribute (many SSDs) gets no series for it, never a zero.
ATA_ATTRIBUTES = {
    5: "truenas_smart_reallocated_sectors",
    187: "truenas_smart_reported_uncorrectable_errors",
    197: "truenas_smart_pending_sectors",
    198: "truenas_smart_offline_uncorrectable_sectors",
}


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


def run_json(argv: list[str], timeout: int = 60) -> dict | list:
    # smartctl exits non-zero to report a failing disk and still prints JSON,
    # so the exit status is not checked here.
    result = subprocess.run(
        argv, capture_output=True, text=True, timeout=timeout, check=False
    )
    return json.loads(result.stdout)


def seconds(value: object) -> float | None:
    """Middleware timestamps are {"$date": milliseconds}."""
    if isinstance(value, dict) and value.get("$date"):
        return value["$date"] / 1000
    return None


def collect_vdev(out, pool, device_class, node, parent, disks) -> None:
    labels = {
        "pool": pool,
        "class": device_class,
        "vdev": node["name"],
        "type": node["type"],
        "parent": parent,
    }
    if node["type"] == "DISK":
        missing = node.get("unavail_disk") or {}
        name = node.get("disk") or missing.get("name")
        labels["disk"] = name
        labels["serial"] = disks.get(name) or missing.get("serial")
    out.add("truenas_pool_vdev_state", 1, state=node["status"], **labels)
    stats = node.get("stats") or {}
    for kind in ("read", "write", "checksum"):
        out.add(
            "truenas_pool_vdev_errors", stats.get(kind + "_errors") or 0, kind=kind, **labels
        )
    for child in node.get("children") or []:
        collect_vdev(out, pool, device_class, child, node["name"], disks)


def collect_pool(out, pool, disks) -> None:
    name = pool["name"]
    out.add("truenas_pool_state", 1, pool=name, state=pool["status"])
    out.add("truenas_pool_healthy", int(bool(pool["healthy"])), pool=name)
    scan = pool.get("scan") or {}
    out.add(
        "truenas_pool_scan_in_progress", int(scan.get("state") == "SCANNING"), pool=name
    )
    finished = seconds(scan.get("end_time"))
    if scan.get("state") == "FINISHED" and finished:
        function = scan.get("function")
        out.add(
            "truenas_pool_last_scan_end_timestamp_seconds", int(finished), pool=name, function=function
        )
        out.add(
            "truenas_pool_last_scan_errors", scan.get("errors") or 0, pool=name, function=function
        )
    for device_class, nodes in pool["topology"].items():
        for node in nodes:
            collect_vdev(out, name, device_class, node, "", disks)


def collect_pools(out, disks) -> None:
    for source, method in (("pool", "pool.query"), ("boot_pool", "boot.get_state")):
        try:
            data = run_json(["midclt", "call", method])
            for pool in data if isinstance(data, list) else [data]:
                collect_pool(out, pool, disks)
            out.add("truenas_health_collect_ok", 1, source=source)
        except Exception as error:  # a schema change must not stop the rest
            print("%s: %r" % (method, error), file=sys.stderr)
            out.add("truenas_health_collect_ok", 0, source=source)


def collect_smart(out, disk) -> None:
    labels = {"disk": disk["name"], "serial": disk.get("serial")}
    out.add("truenas_disk_info", 1, model=disk.get("model"), type=disk.get("type"), **labels)
    data = run_json(
        ["smartctl", "-j", "-a", "-n", "standby", "/dev/" + disk["name"]], timeout=30
    )
    if "STANDBY" in json.dumps(data.get("smartctl", {}).get("messages", [])):
        return  # asleep: leave it alone, the series just carry no new sample
    if data.get("smartctl", {}).get("exit_status", 0) & 3:
        raise RuntimeError("smartctl could not read the disk")
    passed = data.get("smart_status", {}).get("passed")
    if passed is not None:
        out.add("truenas_smart_healthy", int(passed), **labels)
    for attribute in data.get("ata_smart_attributes", {}).get("table", []):
        if attribute["id"] in ATA_ATTRIBUTES:
            out.add(ATA_ATTRIBUTES[attribute["id"]], attribute["raw"]["value"], **labels)
    # smartctl lists the newest test first, in "extended" or else "standard".
    log = data.get("ata_smart_self_test_log", {})
    tests = (log.get("extended") or log.get("standard") or {}).get("table", [])
    if tests:
        failed = tests[0]["status"].get("passed") is False
        out.add("truenas_smart_selftest_failed", int(failed), **labels)
    nvme = data.get("nvme_smart_health_information_log")
    if nvme:
        out.add("truenas_smart_nvme_critical_warning", nvme["critical_warning"], **labels)
        out.add("truenas_smart_nvme_media_errors", nvme["media_errors"], **labels)
        out.add("truenas_smart_nvme_percentage_used", nvme["percentage_used"], **labels)


def cron_field(text: object, low: int, high: int, names: dict[str, int] | None = None) -> set[int]:
    """Expands one cron field ("*", "5", "1,3", "0-6", "*/15", "mon-fri") to its values."""

    def number(item: str) -> int:
        value = (names or {}).get(item)
        return int(item) if value is None else value

    values: set[int] = set()
    for part in str(text).strip().lower().split(","):
        spec, slash, step_text = part.partition("/")
        step = int(step_text) if slash else 1
        if step < 1:
            raise ValueError("bad step in %r" % (text,))
        if spec in ("", "*"):
            start, end = low, high
        elif "-" in spec:
            first, last = spec.split("-", 1)
            start, end = number(first), number(last)
        else:
            start = number(spec)
            end = high if slash else start
        if start < low or end > high or start > end:
            raise ValueError("%r is outside %d-%d" % (text, low, high))
        values.update(range(start, end + 1, step))
    return values


def clock_minutes(text: object, default: int) -> int:
    """"HH:MM" (a snapshot window edge) as minutes after midnight."""
    if not text:
        return default
    hour, minute = str(text).split(":")[:2]
    return int(hour) * 60 + int(minute)


def last_scheduled(schedule: dict, now: datetime.datetime) -> float | None:
    """The newest time at or before `now` that a TrueNAS cron schedule fires.

    The schedule is {minute, hour, dom, month, dow} plus, for snapshot and
    replication tasks, a daily window {begin, end}. It is read in the host's
    local time zone, which is what TrueNAS runs cron in. None when the schedule
    has not fired in the last 400 days.
    """
    minutes = sorted(cron_field(schedule.get("minute", "*"), 0, 59), reverse=True)
    hours = sorted(cron_field(schedule.get("hour", "*"), 0, 23), reverse=True)
    months = cron_field(schedule.get("month", "*"), 1, 12, MONTHS)
    days = cron_field(schedule.get("dom", "*"), 1, 31)
    # cron accepts both 0 and 7 for Sunday
    weekdays = {day % 7 for day in cron_field(schedule.get("dow", "*"), 0, 7, WEEKDAYS)}
    any_day = str(schedule.get("dom", "*")).strip() == "*"
    any_weekday = str(schedule.get("dow", "*")).strip() == "*"
    begin = clock_minutes(schedule.get("begin"), 0)
    end = clock_minutes(schedule.get("end"), 24 * 60 - 1)
    for back in range(400):
        day = now.date() - datetime.timedelta(days=back)
        if day.month not in months:
            continue
        by_day, by_weekday = day.day in days, day.isoweekday() % 7 in weekdays
        # cron fires on either match when both day fields are restricted
        if any_day and any_weekday:
            fires = True
        elif any_day:
            fires = by_weekday
        elif any_weekday:
            fires = by_day
        else:
            fires = by_day or by_weekday
        if not fires:
            continue
        for hour in hours:
            for minute in minutes:
                moment = datetime.datetime(day.year, day.month, day.day, hour, minute)
                if moment <= now and begin <= hour * 60 + minute <= end:
                    return time.mktime(moment.timetuple())
    return None


MONTHS = {
    name: number
    for number, name in enumerate(
        "jan feb mar apr may jun jul aug sep oct nov dec".split(), start=1
    )
}
WEEKDAYS = {name: number for number, name in enumerate("sun mon tue wed thu fri sat".split())}

# Middleware state -> the one vocabulary the metrics use.
JOB_STATES = {
    "SUCCESS": "SUCCESS",
    "FAILED": "FAILED",
    "RUNNING": "RUNNING",
    "ABORTED": "ABORTED",
    "WAITING": "PENDING",
}
TASK_STATES = {
    "FINISHED": "SUCCESS",
    "ERROR": "FAILED",
    "RUNNING": "RUNNING",
    "PENDING": "PENDING",
    "WAITING": "PENDING",
    "HOLD": "PENDING",
}

# (type label, middleware query, field that names the task)
TASK_SOURCES = (
    ("cloudsync", "cloudsync.query", ("description",)),
    ("replication", "replication.query", ("name",)),
    ("snapshot", "pool.snapshottask.query", ("dataset",)),
    ("rsync", "rsynctask.query", ("desc", "path")),
)


def task_status(task: dict) -> tuple[str, float | None]:
    """The last result and when it ran, from the task's `state` or its last `job`.

    Cloud sync and rsync tasks carry the last middleware job. Snapshot and
    replication tasks carry the replication engine's state, which TrueNAS keeps
    in memory (a task shows PENDING again after a reboot), so a replication task
    falls back to its last job.
    """
    state = task.get("state") or {}
    job = task.get("job") or {}
    status = TASK_STATES.get(str(state.get("state")).upper()) if state else None
    if status and status != "PENDING":
        return status, seconds(state.get("datetime"))
    if job.get("state"):
        raw = str(job["state"]).upper()
        return JOB_STATES.get(raw, raw), seconds(job.get("time_started"))
    return status or "PENDING", seconds(state.get("datetime"))


def collect_task(out, kind: str, name_fields: tuple[str, ...], task: dict, now: float) -> None:
    name = next((task[field] for field in name_fields if task.get(field)), "#%s" % task["id"])
    labels = {"type": kind, "task": name, "id": task["id"]}
    enabled = bool(task.get("enabled"))
    status, ran = task_status(task)
    out.add("truenas_task_enabled", int(enabled), **labels)
    out.add("truenas_task_state", 1, state=status, **labels)
    out.add("truenas_task_failed", int(status == "FAILED"), **labels)
    out.add("truenas_task_running", int(status == "RUNNING"), **labels)
    if ran:
        out.add("truenas_task_last_run_timestamp_seconds", int(ran), **labels)
    schedule = task.get("schedule")
    if enabled and isinstance(schedule, dict):
        try:
            due = last_scheduled(schedule, datetime.datetime.fromtimestamp(now))
        except Exception as error:  # a schedule we cannot read only loses its overdue check
            print("%s %s schedule: %r" % (kind, name, error), file=sys.stderr)
            due = None
        if due:
            out.add("truenas_task_last_scheduled_timestamp_seconds", int(due), **labels)


def collect_tasks(out, now: float) -> None:
    for kind, method, name_fields in TASK_SOURCES:
        source = "tasks_" + kind
        try:
            tasks = run_json(["midclt", "call", method])
            for task in tasks:
                collect_task(out, kind, name_fields, task, now)
            out.add("truenas_health_collect_ok", 1, source=source)
        except Exception as error:  # one task type changing must not stop the rest
            print("%s: %r" % (method, error), file=sys.stderr)
            out.add("truenas_health_collect_ok", 0, source=source)


def collect_job_history(out) -> None:
    """The middleware's recent jobs, summarised per method.

    Covers anything the task types above do not (a manual run, a scrub, a
    replication started by hand): the newest result per method and how many of
    each state are still in the history.
    """
    try:
        options = {
            "order_by": ["-id"],
            "limit": 1000,
            "select": ["id", "method", "state", "time_finished"],
        }
        jobs = run_json(["midclt", "call", "core.get_jobs", "[]", json.dumps(options)])
        newest: dict[str, dict] = {}
        counts: dict[tuple[str, str], int] = {}
        for job in jobs:  # newest first
            method = job["method"]
            raw = str(job["state"]).upper()
            state = JOB_STATES.get(raw, raw)
            newest.setdefault(method, {**job, "state": state})
            counts[(method, state)] = counts.get((method, state), 0) + 1
        for method, job in newest.items():
            out.add("truenas_job_last_state", 1, method=method, state=job["state"])
            finished = seconds(job.get("time_finished"))
            if finished:
                out.add(
                    "truenas_job_last_finished_timestamp_seconds", int(finished), method=method
                )
        for (method, state), count in counts.items():
            out.add("truenas_job_history_jobs", count, method=method, state=state)
        out.add("truenas_health_collect_ok", 1, source="job_history")
    except Exception as error:
        print("core.get_jobs: %r" % (error,), file=sys.stderr)
        out.add("truenas_health_collect_ok", 0, source="job_history")


def collect(out) -> None:
    now = time.time()
    try:
        disks = run_json(["midclt", "call", "disk.query"])
        out.add("truenas_health_collect_ok", 1, source="disks")
    except Exception as error:
        print("disk.query: %r" % (error,), file=sys.stderr)
        out.add("truenas_health_collect_ok", 0, source="disks")
        disks = []
    collect_pools(out, {disk["name"]: disk.get("serial") for disk in disks})
    collect_tasks(out, now)
    collect_job_history(out)
    for disk in disks:
        try:
            collect_smart(out, disk)
            out.add("truenas_smart_collect_ok", 1, disk=disk["name"], serial=disk.get("serial"))
        except Exception as error:
            print("smartctl %s: %r" % (disk["name"], error), file=sys.stderr)
            out.add("truenas_smart_collect_ok", 0, disk=disk["name"], serial=disk.get("serial"))


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("print", "push") or (argv[0] == "push" and len(argv) != 2):
        print(__doc__, file=sys.stderr)
        return 2
    started = time.time()
    out = Metrics()
    collect(out)
    out.add("truenas_health_collect_duration_seconds", round(time.time() - started, 3))
    # The heartbeat goes last, so it only appears when the run got this far.
    out.add("truenas_health_push_timestamp_seconds", int(time.time()))
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
