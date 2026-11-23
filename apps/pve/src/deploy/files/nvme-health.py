"""Reports the SMART health of the NVMe drives of this Proxmox host as Prometheus metrics.

Proxmox pushes host load and disk usage through its InfluxDB metric server, but
nothing there says whether a drive is wearing out or failing. The stalls that
broke etcd on the k8s-main guest came from the NVMe under this host, and
node-exporter in the guest cannot read its SMART log. This script fills the gap.
It runs from a systemd timer that apps/pve installs and uses only python3 (standard
library) and `nvme smart-log` from nvme-cli.

    python3 nvme-health.py print        write the metrics to stdout (a dry run)
    python3 nvme-health.py push <url>   POST them to a VictoriaMetrics /api/v1/import/prometheus URL

A drive that cannot be read is reported as nvme_health_collect_ok 0 and leaves its
SMART series out. The heartbeat is written last, so it only appears when the run
got that far.
"""

from __future__ import annotations

import glob
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

# Seconds `nvme smart-log` may take. A drive that has stopped answering must not
# take the run (and the heartbeat) with it.
COMMAND_TIMEOUT = 30
# Metric name -> field in the JSON of `nvme smart-log`.
SMART_FIELDS = {
    "nvme_smart_critical_warning": "critical_warning",
    "nvme_smart_percentage_used": "percent_used",
    "nvme_smart_available_spare_percent": "avail_spare",
    "nvme_smart_available_spare_threshold_percent": "spare_thresh",
    "nvme_smart_media_errors": "media_errors",
    "nvme_smart_error_log_entries": "num_err_log_entries",
    "nvme_smart_unsafe_shutdowns": "unsafe_shutdowns",
    "nvme_smart_power_on_hours": "power_on_hours",
    "nvme_smart_data_units_written": "data_units_written",
    "nvme_smart_data_units_read": "data_units_read",
    "nvme_smart_warning_temperature_seconds": "warning_temp_time",
    "nvme_smart_critical_temperature_seconds": "critical_comp_time",
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


def controllers() -> list[str]:
    """The NVMe controllers of the host, such as nvme0 (not the namespaces, nvme0n1)."""
    return sorted(os.path.basename(path) for path in glob.glob("/sys/class/nvme/nvme[0-9]*"))


def read_sysfs(controller: str, name: str) -> str:
    try:
        with open("/sys/class/nvme/%s/%s" % (controller, name)) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def capacity_bytes(controller: str) -> int | None:
    """The size of the drive: its namespaces (nvme0n1, ...) hold it in 512 byte sectors."""
    sizes = []
    for path in glob.glob("/sys/class/nvme/%s/%sn[0-9]*/size" % (controller, controller)):
        try:
            with open(path) as handle:
                sizes.append(int(handle.read().strip()) * 512)
        except (OSError, ValueError):
            pass
    return sum(sizes) if sizes else None


def smart_log(controller: str) -> dict:
    result = subprocess.run(
        ["nvme", "smart-log", "/dev/" + controller, "--output-format=json"],
        capture_output=True,
        text=True,
        timeout=COMMAND_TIMEOUT,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "exit code %s" % result.returncode)
    return json.loads(result.stdout)


def celsius(temperature: float) -> float:
    """nvme-cli 2.x prints the composite temperature in kelvin, 1.x in degrees Celsius."""
    return round(temperature - 273.15, 2) if temperature > 200 else temperature


def number(value: object) -> float | None:
    """A number from the JSON of `nvme smart-log`, or None.

    nvme-cli prints most fields as numbers, but the 128-bit counters (media errors,
    power on hours, data units, unsafe shutdowns, error log entries) can arrive as a
    string of digits. Taking only int and float silently dropped those series, which
    left the media error alert with nothing to read.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value)
    return None


def add_smart(out: Metrics, log: dict, **labels: object) -> None:
    for metric, field in SMART_FIELDS.items():
        value = number(log.get(field))
        if value is not None:
            out.add(metric, value, **labels)
        elif field in log:
            print("%s: %s has an unreadable value %r" % (labels.get("device"), field, log[field]), file=sys.stderr)
    temperature = number(log.get("temperature"))
    if temperature is not None:
        out.add("nvme_smart_temperature_celsius", celsius(temperature), **labels)


def collect(out: Metrics, host: str) -> None:
    drives = controllers()
    # A host with no NVMe drive has nothing to report, which is not a failure.
    out.add("nvme_health_drives", len(drives), host=host)
    for controller in drives:
        labels = {
            "host": host,
            "device": controller,
            "model": read_sysfs(controller, "model"),
            "serial": read_sysfs(controller, "serial"),
        }
        try:
            add_smart(out, smart_log(controller), **labels)
            size = capacity_bytes(controller)
            if size is not None:
                out.add("nvme_capacity_bytes", size, **labels)
            ok = 1
        except Exception as error:  # a bad drive or a CLI change must not stop the rest
            print("%s: %r" % (controller, error), file=sys.stderr)
            ok = 0
        out.add("nvme_health_collect_ok", ok, host=host, device=controller)


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("print", "push") or (argv[0] == "push" and len(argv) != 2):
        print(__doc__, file=sys.stderr)
        return 2
    host = socket.gethostname()
    out = Metrics()
    collect(out, host)
    out.add("nvme_health_push_timestamp_seconds", int(time.time()), host=host)
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
