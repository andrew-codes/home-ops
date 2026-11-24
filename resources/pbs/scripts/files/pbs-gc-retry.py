"""Retries a Proxmox Backup Server garbage collection that failed.

A garbage collection of an S3 datastore makes a very large number of requests,
and the bucket can answer "SlowDown" (HTTP 503) part way through. PBS does not
retry the run, so the datastore keeps its pruned chunks, and the space is not
freed until the next scheduled run, which can be days away. This script runs
from a systemd timer that resources/pbs installs, finds a datastore whose last
garbage collection failed, and starts it again with bounded retries and an
exponential backoff. It uses only what the host ships: python3 (standard
library only) and proxmox-backup-debug, which calls the local PBS API as root.

    python3 pbs-gc-retry.py run       retry what is due (what the timer runs)
    python3 pbs-gc-retry.py status    show what `run` would do, and change nothing

It is meant to be safe to run as often as the timer likes:

  - It never starts a garbage collection while any garbage collection task is
    running, and a lock file keeps two copies of the script from running at once.
  - Retries of one failure are spaced BASE_BACKOFF * 2^n apart, measured from
    the end of the failed run, and stop after MAX_ATTEMPTS. At most
    MAX_STARTS_PER_DAY are started in any 24 hours, however many failures there
    are.
  - A failure it did not start itself (the scheduled run, or one started by
    hand) opens a new episode with a fresh set of attempts. A success closes it.
  - It only starts a garbage collection. It never changes the datastore, the
    schedule or any other PBS configuration.

The result of a retry is the same as a scheduled run's: PBS records it as the
last run of the garbage collection job, which is what pbs-health.py reads for
pbs_job_last_run_ok, so the failed-GC alert clears when a retry succeeds. The
episode state is kept in STATE_PATH, and pbs-health.py reports it as
pbs_gc_retry_attempts and pbs_gc_retry_exhausted, for the alert that says the
retries ran out. Every decision is logged as key=value to stdout and stderr, so
it reaches the journal and then VictoriaLogs.
"""

from __future__ import annotations

import fcntl
import json
import os
import signal
import subprocess
import sys
import time

# The first retry waits this long after the failed run ended, and each further
# one twice as long as the one before: 10, 20, 40, 80 and 160 minutes.
BASE_BACKOFF = 10 * 60
# Retries of one failure. When they are used up, the failure is left for a person.
MAX_ATTEMPTS = 5
# Garbage collections this script starts in any 24 hours, over all episodes.
MAX_STARTS_PER_DAY = 6
DAY = 24 * 3600
# How far back to look for garbage collection tasks that are still running.
TASK_LOOKBACK = 3 * 24 * 3600
# The upids of its own runs that an episode remembers.
KEEP_UPIDS = 20
# Seconds a single API call may take.
API_TIMEOUT = 30
STATE_PATH = os.environ.get("PBS_GC_RETRY_STATE", "/var/lib/pbs-gc-retry/state.json")
LOCK_PATH = os.environ.get("PBS_GC_RETRY_LOCK", "/run/pbs-gc-retry.lock")

PRIORITY = {"error": 3, "warning": 4, "info": 6}


def log(level: str, event: str, **fields: object) -> None:
    """One key=value line. The <n> prefix is the journal priority systemd reads."""
    text = " ".join(
        "%s=%s" % (key, json.dumps(value) if isinstance(value, str) else value)
        for key, value in fields.items()
    )
    stream = sys.stderr if level == "error" else sys.stdout
    print("<%d>event=%s %s" % (PRIORITY[level], event, text), file=stream, flush=True)


def run(argv: list[str], timeout: int = API_TIMEOUT) -> subprocess.CompletedProcess:
    """Run a command, and give up on it after `timeout` seconds (see pbs-health.py)."""
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
        try:
            child.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        raise
    return subprocess.CompletedProcess(argv, child.returncode, stdout, stderr)


def api(verb: str, path: str, *params: str, timeout: int = API_TIMEOUT):
    argv = ["proxmox-backup-debug", "api", verb, path, "--output-format", "json"]
    result = run(argv + list(params), timeout)
    if result.returncode != 0:
        raise RuntimeError("%s: %s" % (path, result.stderr.strip() or result.returncode))
    return json.loads(result.stdout)


def task_ok(state: object) -> bool:
    """A task state is "OK", "WARNINGS: n" or the error text. Warnings are not failures."""
    return isinstance(state, str) and (state == "OK" or state.startswith("WARNINGS"))


def gc_running(tasks: list[dict]) -> list[str]:
    """The datastores that have a garbage collection task without an end time."""
    return [
        task.get("worker_id") or "?"
        for task in tasks
        if task.get("worker_type") == "garbage_collection" and not task.get("endtime")
    ]


def load_state(path: str) -> dict:
    try:
        with open(path) as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as error:
        # Written atomically, so this is a hand edit or a full disk. Starting
        # over cannot loop: the per day cap is rebuilt from what is started now.
        log("warning", "state-unreadable", path=path, error=repr(error))
        return {}
    return state if isinstance(state, dict) else {}


def save_state(path: str, state: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def new_entry() -> dict:
    return {"attempts": 0, "exhausted": False, "episode_upid": None, "upids": [], "starts": []}


def decide(job: dict, entry: dict, now: float) -> tuple[str, str]:
    """What to do about one datastore: (action, reason). `entry` is updated in place.

    The action is one of "ok", "wait", "capped", "exhausted" or "start". Nothing
    here starts anything, so `status` can show the same decision `run` acts on.
    """
    state = job.get("last-run-state")
    # A job that has not run yet has no state, and a good run needs no retry.
    if state is None or task_ok(state):
        entry.update(attempts=0, exhausted=False, episode_upid=None, upids=[])
        return "ok", "last run succeeded" if state is not None else "never run"
    upid = job.get("last-run-upid")
    known = set(entry["upids"]) | {entry["episode_upid"]}
    if upid not in known:
        # A scheduled run or a run by hand failed: a new episode, a fresh budget.
        entry.update(attempts=0, exhausted=False, episode_upid=upid, upids=[])
    if entry["attempts"] >= MAX_ATTEMPTS:
        entry["exhausted"] = True
        return "exhausted", "all %d retries used" % MAX_ATTEMPTS
    entry["exhausted"] = False
    due = (job.get("last-run-endtime") or now) + BASE_BACKOFF * 2 ** entry["attempts"]
    if now < due:
        return "wait", "next retry in %ds" % round(due - now)
    entry["starts"] = [t for t in entry["starts"] if now - t < DAY]
    if len(entry["starts"]) >= MAX_STARTS_PER_DAY:
        return "capped", "%d starts in the last 24 hours" % len(entry["starts"])
    return "start", "retry %d of %d" % (entry["attempts"] + 1, MAX_ATTEMPTS)


def start_gc(store: str) -> str:
    result = api("create", "/admin/datastore/%s/gc" % store)
    return result if isinstance(result, str) else json.dumps(result)


def retry(now: float, dry_run: bool) -> int:
    """Look at every datastore once. The exit status is 1 when PBS could not be read."""
    try:
        jobs = [job for job in api("get", "/admin/gc") if job.get("store")]
        tasks = api(
            "get",
            "/nodes/localhost/tasks",
            "--typefilter", "garbage_collection",
            "--since", str(int(now - TASK_LOOKBACK)),
            "--limit", "0",
        )
    except Exception as error:  # nothing is started on a guess
        log("error", "read-failed", error=repr(error))
        return 1
    running = gc_running(tasks)
    state = load_state(STATE_PATH)
    failed = False
    for job in sorted(jobs, key=lambda item: item["store"]):
        store = job["store"]
        entry = {**new_entry(), **state.get(store, {})}
        action, reason = decide(job, entry, now)
        fields = {"datastore": store, "attempts": entry["attempts"], "reason": reason}
        if action == "start" and running:
            # Any garbage collection, not only this datastore's: one at a time.
            action, reason = "running", "garbage collection running on %s" % ",".join(running)
            fields["reason"] = reason
        if action == "start" and dry_run:
            action = "would-start"
        elif action == "start":
            # Counted before the call, so a start that errors still uses an attempt.
            entry["attempts"] += 1
            entry["starts"].append(now)
            fields["attempts"] = entry["attempts"]
            state[store] = entry
            save_state(STATE_PATH, state)
            try:
                upid = start_gc(store)
            except Exception as error:
                log("error", "start-failed", error=repr(error), **fields)
                failed = True
                continue
            entry["upids"] = (entry["upids"] + [upid])[-KEEP_UPIDS:]
            running.append(store)
            fields["upid"] = upid
        level = "error" if action == "exhausted" else "warning" if action == "capped" else "info"
        log(level, action, **fields)
        if not dry_run:
            state[store] = entry
    if not dry_run:
        save_state(STATE_PATH, state)
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if len(argv) != 1 or argv[0] not in ("run", "status"):
        print(__doc__, file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    with open(LOCK_PATH, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("info", "skip", reason="another run holds the lock")
            return 0
        return retry(time.time(), dry_run=argv[0] == "status")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
