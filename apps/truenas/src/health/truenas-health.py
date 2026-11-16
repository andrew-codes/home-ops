"""Reports ZFS pool, vdev and SMART health from a TrueNAS host as Prometheus metrics.

It runs on the NAS as a TrueNAS cron job that apps/truenas installs, and uses
only what the appliance ships: python3 (standard library only), midclt and
smartctl. Pool and disk state come from the middleware (pool.query,
boot.get_state, disk.query), SMART from `smartctl -j`, because TrueNAS 25.10
removed its SMART API.

    python3 truenas-health.py print         write the metrics to stdout (a dry run)
    python3 truenas-health.py push <url>    POST them to a VictoriaMetrics /api/v1/import/prometheus URL

A source that fails (a middleware call, one disk) is reported as
truenas_health_collect_ok 0 and leaves its other series out, so one bad disk
does not hide the rest.
"""

from __future__ import annotations

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


def collect(out) -> None:
    try:
        disks = run_json(["midclt", "call", "disk.query"])
        out.add("truenas_health_collect_ok", 1, source="disks")
    except Exception as error:
        print("disk.query: %r" % (error,), file=sys.stderr)
        out.add("truenas_health_collect_ok", 0, source="disks")
        disks = []
    collect_pools(out, {disk["name"]: disk.get("serial") for disk in disks})
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
