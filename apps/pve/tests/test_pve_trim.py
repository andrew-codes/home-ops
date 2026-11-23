"""Unit tests for src/deploy/files/pve-trim.sh. Run with `python3 -m unittest discover -s apps/pve/tests`.

`pct` and `curl` are stand-ins on PATH, so the script runs for real without a
Proxmox host: the stand-in pct prints the `pct list` table and records each fstrim.
"""

import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "src" / "deploy" / "files" / "pve-trim.sh"

PCT = """#!/bin/sh
case "$1" in
list)
  echo "VMID       Status     Lock         Name"
  echo "20130      running                 pihole-a"
  echo "20131      stopped                 pihole-b"
  echo "20144      running                 node"
  echo "20170      running                 subnet-router"
  ;;
fstrim)
  echo "$2" >> "$TRIM_LOG"
  for failing in $FAIL_IDS; do [ "$failing" = "$2" ] && exit 1; done
  ;;
esac
exit 0
"""

CURL = """#!/bin/sh
echo "$@" > "$CURL_ARGS"
cat > "$CURL_BODY"
exit "${CURL_EXIT:-0}"
"""


class PveTrimTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        root = pathlib.Path(self.dir.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in (("pct", PCT), ("curl", CURL)):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        self.root = root
        self.env = dict(
            os.environ,
            PATH="%s:%s" % (bin_dir, os.environ["PATH"]),
            TRIM_LOG=str(root / "trim.log"),
            CURL_ARGS=str(root / "curl.args"),
            CURL_BODY=str(root / "curl.body"),
        )

    def run_script(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env=dict(self.env, **env),
        )

    def trimmed(self):
        log = self.root / "trim.log"
        return log.read_text().split() if log.exists() else []

    def test_trims_only_running_containers(self):
        result = self.run_script("print")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.trimmed(), ["20130", "20144", "20170"])

    def test_a_clean_run_reports_the_last_success(self):
        out = self.run_script("print").stdout
        self.assertIn("pve_trim_containers_trimmed{host=", out)
        self.assertRegex(out, r'pve_trim_containers_trimmed\{host="[^"]+"\} 3\n')
        self.assertRegex(out, r'pve_trim_containers_failed\{host="[^"]+"\} 0\n')
        self.assertRegex(out, r'pve_trim_last_success_timestamp_seconds\{host="[^"]+"\} \d+\n')

    def test_a_failed_container_is_counted_and_does_not_stop_the_others(self):
        result = self.run_script("print", FAIL_IDS="20144")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.trimmed(), ["20130", "20144", "20170"])
        self.assertRegex(result.stdout, r'pve_trim_containers_failed\{host="[^"]+"\} 1\n')
        self.assertRegex(result.stdout, r"pve_trim_last_run_timestamp_seconds")
        self.assertNotIn("pve_trim_last_success_timestamp_seconds", result.stdout)
        self.assertIn("pct fstrim 20144 failed", result.stderr)

    def test_push_posts_the_metrics_to_the_url(self):
        url = "http://10.0.0.1:30080/api/v1/import/prometheus"
        result = self.run_script("push", url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(url, (self.root / "curl.args").read_text())
        self.assertIn("pve_trim_last_success_timestamp_seconds", (self.root / "curl.body").read_text())

    def test_a_failed_push_fails_the_run(self):
        result = self.run_script("push", "http://x/y", CURL_EXIT="22")
        self.assertEqual(result.returncode, 1)
        self.assertIn("push to http://x/y failed", result.stderr)

    def test_bad_usage_prints_help(self):
        for args in ((), ("push",), ("print", "extra"), ("nope",)):
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 2, args)
            self.assertIn("pve-trim.sh print", result.stderr)


if __name__ == "__main__":
    unittest.main()
