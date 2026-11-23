"""Unit tests for src/deploy/files/nvme-health.py. Run with `python3 -m unittest discover -s apps/pve/tests`.

The `nvme smart-log --output-format=json` answers are written out here in the
shape nvme-cli prints them, so a change to the script that stops it reading a
field fails here instead of on the real host.
"""

import importlib.util
import json
import pathlib
import subprocess
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "src" / "deploy" / "files" / "nvme-health.py"
spec = importlib.util.spec_from_file_location("nvme_health", SCRIPT)
nvme_health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nvme_health)

# nvme-cli 2.x: the temperature is in kelvin (306 K = 32.85 C).
SMART_LOG = {
    "critical_warning": 0,
    "temperature": 306,
    "avail_spare": 100,
    "spare_thresh": 5,
    "percent_used": 7,
    "data_units_read": 1000,
    "data_units_written": 2000,
    "media_errors": 0,
    "num_err_log_entries": 3,
    "warning_temp_time": 0,
    "critical_comp_time": 0,
    "unsafe_shutdowns": 12,
    "power_on_hours": 9000,
}


def collect(smart=None, controllers=("nvme0",), fail=None):
    out = nvme_health.Metrics()

    def log(controller):
        if fail and controller in fail:
            raise RuntimeError("Failed to open /dev/%s" % controller)
        return smart if smart is not None else SMART_LOG

    with mock.patch.object(nvme_health, "controllers", return_value=list(controllers)), \
         mock.patch.object(nvme_health, "smart_log", side_effect=log), \
         mock.patch.object(nvme_health, "read_sysfs", side_effect=lambda c, n: {"model": "Sabrent", "serial": "S1"}[n]):
        nvme_health.collect(out, "pve")
    return out.lines


class CollectTest(unittest.TestCase):
    def test_reports_every_smart_field_with_the_drive_labels(self):
        lines = collect()
        labels = 'device="nvme0",host="pve",model="Sabrent",serial="S1"'
        for expected in (
            "nvme_smart_critical_warning{%s} 0" % labels,
            "nvme_smart_percentage_used{%s} 7" % labels,
            "nvme_smart_available_spare_percent{%s} 100" % labels,
            "nvme_smart_available_spare_threshold_percent{%s} 5" % labels,
            "nvme_smart_media_errors{%s} 0" % labels,
            "nvme_smart_error_log_entries{%s} 3" % labels,
            "nvme_smart_unsafe_shutdowns{%s} 12" % labels,
            "nvme_smart_power_on_hours{%s} 9000" % labels,
            "nvme_smart_data_units_written{%s} 2000" % labels,
            "nvme_smart_temperature_celsius{%s} 32.85" % labels,
            'nvme_health_collect_ok{device="nvme0",host="pve"} 1',
            'nvme_health_drives{host="pve"} 1',
        ):
            self.assertIn(expected, lines)

    def test_a_celsius_temperature_is_left_alone(self):
        lines = collect({"temperature": 41})
        self.assertIn('nvme_smart_temperature_celsius{device="nvme0",host="pve",model="Sabrent",serial="S1"} 41', lines)

    def test_a_drive_that_cannot_be_read_is_reported_and_the_others_still_are(self):
        lines = collect(controllers=("nvme0", "nvme1"), fail={"nvme0"})
        self.assertIn('nvme_health_collect_ok{device="nvme0",host="pve"} 0', lines)
        self.assertIn('nvme_health_collect_ok{device="nvme1",host="pve"} 1', lines)
        self.assertFalse([l for l in lines if l.startswith("nvme_smart_") and 'device="nvme0"' in l])
        self.assertTrue([l for l in lines if l.startswith("nvme_smart_") and 'device="nvme1"' in l])

    def test_a_host_without_nvme_reports_no_drives_and_no_failure(self):
        lines = collect(controllers=())
        self.assertEqual(lines, ['nvme_health_drives{host="pve"} 0'])


class SmartLogTest(unittest.TestCase):
    def test_parses_the_json_of_nvme_cli(self):
        done = subprocess.CompletedProcess([], 0, json.dumps(SMART_LOG), "")
        with mock.patch.object(nvme_health.subprocess, "run", return_value=done) as run:
            self.assertEqual(nvme_health.smart_log("nvme0"), SMART_LOG)
        self.assertEqual(run.call_args.args[0], ["nvme", "smart-log", "/dev/nvme0", "--output-format=json"])

    def test_a_failing_command_raises_with_its_error(self):
        done = subprocess.CompletedProcess([], 1, "", "Failed to open")
        with mock.patch.object(nvme_health.subprocess, "run", return_value=done):
            with self.assertRaisesRegex(RuntimeError, "Failed to open"):
                nvme_health.smart_log("nvme0")


class EscapeTest(unittest.TestCase):
    def test_escapes_label_values(self):
        out = nvme_health.Metrics()
        out.add("m", 1, model='a"b\\c')
        self.assertEqual(out.lines, ['m{model="a\\"b\\\\c"} 1'])


if __name__ == "__main__":
    unittest.main()
