import { execFile, spawnSync } from "node:child_process"
import fs from "node:fs"
import http from "node:http"
import os from "node:os"
import path from "node:path"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

const script = path.join(__dirname, "..", "truenas-health.py")
const fixtures = path.join(__dirname, "fixtures")

type Sample = { name: string; labels: Record<string, string>; value: number }

type Setup = {
  // fixture file names (without .json) for each middleware call
  pool?: string
  boot?: string
  disks?: string
  cloudsync?: string
  replication?: string
  snapshot?: string
  rsync?: string
  jobs?: string
  // fixture for smartctl by disk name; "default" covers the rest
  smart?: Record<string, string>
  // middleware methods that print garbage and fail
  failing?: string[]
}

const tmpDirs: string[] = []

afterAll(() => {
  tmpDirs.forEach((dir) => fs.rmSync(dir, { recursive: true, force: true }))
})

// Puts stand-in midclt and smartctl executables first on PATH. They print the
// recorded fixtures, so the script runs exactly as it does on the NAS.
const stubs = ({
  pool = "pool_online",
  boot = "boot_online",
  disks = "disks",
  cloudsync = "tasks/cloudsync",
  replication = "tasks/replication",
  snapshot = "tasks/snapshottask",
  rsync = "tasks/rsync",
  jobs = "tasks/jobs",
  smart = {},
  failing = [],
}: Setup = {}): NodeJS.ProcessEnv => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "truenas-health-"))
  tmpDirs.push(dir)
  const fixture = (name: string) => path.join(fixtures, `${name}.json`)
  const methods: Record<string, string> = {
    "pool.query": pool,
    "boot.get_state": boot,
    "disk.query": disks,
    "cloudsync.query": cloudsync,
    "replication.query": replication,
    "pool.snapshottask.query": snapshot,
    "rsynctask.query": rsync,
    "core.get_jobs": jobs,
  }
  const midclt = Object.entries(methods)
    .map(([method, name]) =>
      failing.includes(method)
        ? `  ${method}) echo 'not json'; exit 1;;`
        : `  ${method}) cat '${fixture(name)}';;`,
    )
    .join("\n")
  fs.writeFileSync(
    path.join(dir, "midclt"),
    `#!/bin/sh\ncase "$2" in\n${midclt}\n  *) echo "unexpected: $*" >&2; exit 1;;\nesac\n`,
    { mode: 0o755 },
  )
  const byDisk = Object.entries({ default: "smart/ata_healthy", ...smart })
    .filter(([disk]) => disk !== "default")
    .map(([disk, name]) => `  ${disk}) cat '${fixture(name)}';;`)
    .join("\n")
  // smartctl exits non-zero when a disk is failing, and still prints JSON.
  fs.writeFileSync(
    path.join(dir, "smartctl"),
    `#!/bin/sh\ncase "$(basename "$5")" in\n${byDisk}\n  *) cat '${fixture(smart.default ?? "smart/ata_healthy")}';;\nesac\nexit 8\n`,
    { mode: 0o755 },
  )
  return { ...process.env, PATH: `${dir}:${process.env.PATH}` }
}

const parse = (output: string): Sample[] =>
  output
    .trim()
    .split("\n")
    .map((line) => {
      const match = line.match(/^([a-z_]+)(?:\{(.*)\})? (\S+)$/)
      if (!match) {
        throw new Error(`Not a Prometheus sample line: ${line}`)
      }
      const labels: Record<string, string> = {}
      for (const pair of (match[2] ?? "").matchAll(
        /([a-z_]+)="((?:[^"\\]|\\.)*)"/g,
      )) {
        labels[pair[1]] = pair[2]
      }
      return { name: match[1], labels, value: Number(match[3]) }
    })

const collect = (setup?: Setup): Sample[] => {
  const result = spawnSync("python3", [script, "print"], {
    env: stubs(setup),
    encoding: "utf8",
  })
  expect(result.status).toBe(0)
  return parse(result.stdout)
}

const find = (
  samples: Sample[],
  name: string,
  labels: Record<string, string> = {},
): Sample[] =>
  samples.filter(
    (sample) =>
      sample.name === name &&
      Object.entries(labels).every(
        ([key, value]) => sample.labels[key] === value,
      ),
  )

const valueOf = (
  samples: Sample[],
  name: string,
  labels: Record<string, string> = {},
): number | undefined => {
  const found = find(samples, name, labels)
  expect(found.length).toBeLessThanOrEqual(1)
  return found[0]?.value
}

describe("truenas-health.py", () => {
  describe("healthy host", () => {
    let samples: Sample[]
    beforeAll(() => {
      samples = collect()
    })

    it("reports every pool, including the boot pool, as ONLINE and healthy", () => {
      for (const pool of ["fast", "tank", "boot-pool"]) {
        expect(
          valueOf(samples, "truenas_pool_state", { pool, state: "ONLINE" }),
        ).toBe(1)
        expect(valueOf(samples, "truenas_pool_healthy", { pool })).toBe(1)
      }
      expect(find(samples, "truenas_pool_state")).toHaveLength(3)
    })

    it("reports the state of each vdev and the disk under it, named by serial", () => {
      expect(
        valueOf(samples, "truenas_pool_vdev_state", {
          pool: "tank",
          type: "RAIDZ3",
          vdev: "raidz3-0",
          state: "ONLINE",
        }),
      ).toBe(1)
      const disks = find(samples, "truenas_pool_vdev_state", {
        pool: "tank",
        type: "DISK",
        parent: "raidz3-0",
      })
      expect(disks).toHaveLength(10)
      expect(disks.every((disk) => disk.labels.state === "ONLINE")).toBe(true)
      expect(disks.map((disk) => disk.labels.serial)).toContain("SERIAL-SDA")
      expect(disks.map((disk) => disk.labels.disk)).toContain("sda")
    })

    it("reports a mirror and a boot disk the same way", () => {
      expect(
        find(samples, "truenas_pool_vdev_state", {
          pool: "fast",
          type: "MIRROR",
        }),
      ).toHaveLength(1)
      expect(
        valueOf(samples, "truenas_pool_vdev_state", {
          pool: "boot-pool",
          type: "DISK",
          disk: "nvme0n1",
          serial: "SERIAL-NVME0N1",
        }),
      ).toBe(1)
    })

    it("reports read, write and checksum errors for every vdev", () => {
      const errors = find(samples, "truenas_pool_vdev_errors", { pool: "tank" })
      expect(errors).toHaveLength(11 * 3)
      expect(errors.every((error) => error.value === 0)).toBe(true)
      expect(errors.map((error) => error.labels.kind).sort()).toEqual(
        [...Array(11)].flatMap(() => ["checksum", "read", "write"]).sort(),
      )
    })

    it("reports no scan time for a pool that was never scrubbed", () => {
      expect(
        find(samples, "truenas_pool_last_scan_end_timestamp_seconds", {
          pool: "tank",
        }),
      ).toHaveLength(0)
      expect(
        valueOf(samples, "truenas_pool_scan_in_progress", { pool: "tank" }),
      ).toBe(0)
    })

    it("reports the finished boot pool scrub", () => {
      expect(
        valueOf(samples, "truenas_pool_last_scan_end_timestamp_seconds", {
          pool: "boot-pool",
          function: "SCRUB",
        }),
      ).toBe(1794732307)
      expect(
        valueOf(samples, "truenas_pool_last_scan_errors", {
          pool: "boot-pool",
          function: "SCRUB",
        }),
      ).toBe(0)
    })

    it("reports SMART health for every disk and marks every source as collected", () => {
      expect(find(samples, "truenas_smart_healthy")).toHaveLength(13)
      expect(
        find(samples, "truenas_smart_healthy").every(
          (sample) => sample.value === 1,
        ),
      ).toBe(true)
      expect(find(samples, "truenas_smart_collect_ok")).toHaveLength(13)
      for (const source of [
        "disks",
        "pool",
        "boot_pool",
        "tasks_cloudsync",
        "tasks_replication",
        "tasks_snapshot",
        "tasks_rsync",
        "job_history",
      ]) {
        expect(valueOf(samples, "truenas_health_collect_ok", { source })).toBe(
          1,
        )
      }
    })

    it("reports the ATA counters, and leaves out the ones a disk does not have", () => {
      expect(
        valueOf(samples, "truenas_smart_pending_sectors", {
          disk: "sda",
          serial: "SERIAL-SDA",
        }),
      ).toBe(0)
      expect(
        valueOf(samples, "truenas_smart_reallocated_sectors", { disk: "sda" }),
      ).toBe(0)
    })

    it("ends with a heartbeat timestamp", () => {
      const heartbeat = samples[samples.length - 1]
      expect(heartbeat.name).toBe("truenas_health_push_timestamp_seconds")
      expect(Math.abs(heartbeat.value - Date.now() / 1000)).toBeLessThan(60)
    })
  })

  describe("degraded pool", () => {
    let samples: Sample[]
    beforeAll(() => {
      samples = collect({ pool: "pool_degraded" })
    })

    it("reports the pool and the vdev as DEGRADED, and the pool as unhealthy", () => {
      expect(
        valueOf(samples, "truenas_pool_state", {
          pool: "tank",
          state: "DEGRADED",
        }),
      ).toBe(1)
      expect(valueOf(samples, "truenas_pool_healthy", { pool: "tank" })).toBe(0)
      expect(
        valueOf(samples, "truenas_pool_vdev_state", {
          vdev: "raidz3-0",
          state: "DEGRADED",
        }),
      ).toBe(1)
      expect(
        find(samples, "truenas_pool_state", { pool: "tank", state: "ONLINE" }),
      ).toHaveLength(0)
    })

    it("names the faulted disk by serial and the pool it is in", () => {
      const faulted = find(samples, "truenas_pool_vdev_state", {
        state: "FAULTED",
      })
      expect(faulted).toHaveLength(1)
      expect(faulted[0].labels).toMatchObject({
        pool: "tank",
        parent: "raidz3-0",
        disk: "sda",
        serial: "SERIAL-SDA",
        type: "DISK",
      })
      expect(
        valueOf(samples, "truenas_pool_vdev_errors", {
          disk: "sda",
          kind: "checksum",
        }),
      ).toBe(47)
    })

    it("names a removed disk from what the middleware remembers of it", () => {
      const removed = find(samples, "truenas_pool_vdev_state", {
        state: "REMOVED",
      })
      expect(removed).toHaveLength(1)
      expect(removed[0].labels).toMatchObject({
        pool: "tank",
        disk: "sdb",
        serial: "SERIAL-SDB",
      })
    })

    it("leaves the other pools online", () => {
      expect(
        valueOf(samples, "truenas_pool_state", {
          pool: "fast",
          state: "ONLINE",
        }),
      ).toBe(1)
      expect(
        valueOf(samples, "truenas_pool_state", {
          pool: "boot-pool",
          state: "ONLINE",
        }),
      ).toBe(1)
    })
  })

  describe("scans", () => {
    it("reports errors from a finished scrub and a scrub that is still running", () => {
      const samples = collect({ pool: "pool_scans" })
      expect(
        valueOf(samples, "truenas_pool_last_scan_errors", { pool: "tank" }),
      ).toBe(3)
      expect(
        valueOf(samples, "truenas_pool_last_scan_end_timestamp_seconds", {
          pool: "tank",
        }),
      ).toBe(1794086400)
      expect(
        valueOf(samples, "truenas_pool_scan_in_progress", { pool: "fast" }),
      ).toBe(1)
      expect(
        find(samples, "truenas_pool_last_scan_end_timestamp_seconds", {
          pool: "fast",
        }),
      ).toHaveLength(0)
    })
  })

  describe("SMART", () => {
    it("reports a failing ATA disk: health, sector counters and the last self-test", () => {
      const samples = collect({ smart: { sdb: "smart/ata_failing" } })
      const disk = { disk: "sdb", serial: "SERIAL-SDB" }
      expect(valueOf(samples, "truenas_smart_healthy", disk)).toBe(0)
      expect(valueOf(samples, "truenas_smart_reallocated_sectors", disk)).toBe(
        16,
      )
      expect(valueOf(samples, "truenas_smart_pending_sectors", disk)).toBe(8)
      expect(
        valueOf(samples, "truenas_smart_offline_uncorrectable_sectors", disk),
      ).toBe(2)
      expect(
        valueOf(samples, "truenas_smart_reported_uncorrectable_errors", disk),
      ).toBe(2)
      expect(valueOf(samples, "truenas_smart_selftest_failed", disk)).toBe(1)
      expect(valueOf(samples, "truenas_smart_collect_ok", disk)).toBe(1)
    })

    it("reads the standard self-test log, and omits counters a disk does not report", () => {
      const samples = collect({ smart: { sdd: "smart/ata_ssd" } })
      const disk = { disk: "sdd" }
      expect(valueOf(samples, "truenas_smart_selftest_failed", disk)).toBe(0)
      expect(valueOf(samples, "truenas_smart_reallocated_sectors", disk)).toBe(
        0,
      )
      expect(find(samples, "truenas_smart_pending_sectors", disk)).toHaveLength(
        0,
      )
      expect(
        find(samples, "truenas_smart_offline_uncorrectable_sectors", disk),
      ).toHaveLength(0)
    })

    it("reports NVMe health, media errors, wear and the critical warning", () => {
      const healthy = collect({ smart: { nvme0n1: "smart/nvme_healthy" } })
      expect(
        valueOf(healthy, "truenas_smart_nvme_critical_warning", {
          disk: "nvme0n1",
        }),
      ).toBe(0)
      expect(
        valueOf(healthy, "truenas_smart_nvme_percentage_used", {
          disk: "nvme0n1",
        }),
      ).toBe(1)
      expect(
        find(healthy, "truenas_smart_pending_sectors", { disk: "nvme0n1" }),
      ).toHaveLength(0)

      const failing = collect({ smart: { nvme0n1: "smart/nvme_failing" } })
      const disk = { disk: "nvme0n1", serial: "SERIAL-NVME0N1" }
      expect(valueOf(failing, "truenas_smart_healthy", disk)).toBe(0)
      expect(
        valueOf(failing, "truenas_smart_nvme_critical_warning", disk),
      ).toBe(4)
      expect(valueOf(failing, "truenas_smart_nvme_media_errors", disk)).toBe(5)
      expect(valueOf(failing, "truenas_smart_nvme_percentage_used", disk)).toBe(
        92,
      )
    })

    it("does not wake a disk that is in standby, and does not count it as a failure", () => {
      const samples = collect({ smart: { sdc: "smart/standby" } })
      expect(
        find(samples, "truenas_smart_healthy", { disk: "sdc" }),
      ).toHaveLength(0)
      expect(
        valueOf(samples, "truenas_smart_collect_ok", { disk: "sdc" }),
      ).toBe(1)
      expect(find(samples, "truenas_smart_healthy")).toHaveLength(12)
    })

    it("flags a disk smartctl cannot read, and still reports the others", () => {
      const result = spawnSync("python3", [script, "print"], {
        env: stubs({ smart: { sdh: "smart/unreadable" } }),
        encoding: "utf8",
      })
      expect(result.status).toBe(0)
      expect(result.stderr).toContain("smartctl sdh")
      const samples = parse(result.stdout)
      expect(
        valueOf(samples, "truenas_smart_collect_ok", { disk: "sdh" }),
      ).toBe(0)
      expect(
        find(samples, "truenas_smart_healthy", { disk: "sdh" }),
      ).toHaveLength(0)
      expect(find(samples, "truenas_smart_healthy")).toHaveLength(12)
      expect(
        valueOf(samples, "truenas_smart_collect_ok", { disk: "sda" }),
      ).toBe(1)
    })
  })

  describe("scheduled tasks", () => {
    const task = (type: string, name: string) => ({ type, task: name })
    const now = Date.now() / 1000

    it("reports a task that last succeeded", () => {
      const samples = collect()
      const labels = task("cloudsync", "Photos to B2")
      expect(valueOf(samples, "truenas_task_enabled", labels)).toBe(1)
      expect(
        valueOf(samples, "truenas_task_state", { ...labels, state: "SUCCESS" }),
      ).toBe(1)
      expect(valueOf(samples, "truenas_task_failed", labels)).toBe(0)
      expect(valueOf(samples, "truenas_task_running", labels)).toBe(0)
      expect(
        valueOf(samples, "truenas_task_last_run_timestamp_seconds", labels),
      ).toBe(1794790000)
    })

    it("reports a failed cloud sync and a failed replication as failed", () => {
      const samples = collect()
      for (const labels of [
        task("cloudsync", "Documents offsite"),
        task("replication", "tank to backup"),
      ]) {
        expect(valueOf(samples, "truenas_task_failed", labels)).toBe(1)
        expect(
          valueOf(samples, "truenas_task_state", {
            ...labels,
            state: "FAILED",
          }),
        ).toBe(1)
      }
    })

    it("reads replication and snapshot state, and names tasks by dataset or path", () => {
      const samples = collect()
      expect(
        valueOf(
          samples,
          "truenas_task_running",
          task("replication", "fast to tank"),
        ),
      ).toBe(1)
      expect(
        valueOf(samples, "truenas_task_state", {
          ...task("snapshot", "tank/data"),
          state: "SUCCESS",
        }),
      ).toBe(1)
      // an aborted run is not a failure, but it is visible
      const rsync = task("rsync", "/mnt/tank/share")
      expect(
        valueOf(samples, "truenas_task_state", { ...rsync, state: "ABORTED" }),
      ).toBe(1)
      expect(valueOf(samples, "truenas_task_failed", rsync)).toBe(0)
    })

    it("falls back to the last job when the replication engine has forgotten its state", () => {
      const samples = collect()
      const labels = task("replication", "after reboot")
      expect(
        valueOf(samples, "truenas_task_state", { ...labels, state: "SUCCESS" }),
      ).toBe(1)
      expect(
        valueOf(samples, "truenas_task_last_run_timestamp_seconds", labels),
      ).toBe(1794700000)
    })

    it("reports no last run for a task that has never run", () => {
      const samples = collect()
      const archive = task("cloudsync", "Archive")
      expect(
        valueOf(samples, "truenas_task_state", {
          ...archive,
          state: "PENDING",
        }),
      ).toBe(1)
      expect(valueOf(samples, "truenas_task_enabled", archive)).toBe(0)
      expect(
        find(samples, "truenas_task_last_run_timestamp_seconds", archive),
      ).toHaveLength(0)
      const media = task("snapshot", "tank/media")
      expect(
        find(samples, "truenas_task_last_run_timestamp_seconds", media),
      ).toHaveLength(0)
    })

    it("reports when each enabled task was last due, and nothing for a disabled or unscheduled one", () => {
      const samples = collect()
      const due = (labels: Record<string, string>) =>
        valueOf(
          samples,
          "truenas_task_last_scheduled_timestamp_seconds",
          labels,
        )
      const daily = due(task("cloudsync", "Photos to B2"))!
      expect(daily).toBeLessThanOrEqual(now)
      expect(now - daily).toBeLessThan(24 * 3600 + 60)
      const every15 = due(task("snapshot", "tank/data"))!
      expect(now - every15).toBeLessThan(15 * 60 + 60)
      expect(due(task("cloudsync", "Archive"))).toBeUndefined()
      expect(due(task("replication", "tank to backup"))).toBeUndefined()
    })

    it("summarises the job history per method", () => {
      const samples = collect()
      expect(
        valueOf(samples, "truenas_job_last_state", {
          method: "cloudsync.sync",
          state: "FAILED",
        }),
      ).toBe(1)
      expect(
        find(samples, "truenas_job_last_state", {
          method: "cloudsync.sync",
          state: "SUCCESS",
        }),
      ).toHaveLength(0)
      expect(
        valueOf(samples, "truenas_job_last_finished_timestamp_seconds", {
          method: "cloudsync.sync",
        }),
      ).toBe(1794799000)
      expect(
        valueOf(samples, "truenas_job_history_jobs", {
          method: "cloudsync.sync",
          state: "SUCCESS",
        }),
      ).toBe(2)
      expect(
        valueOf(samples, "truenas_job_last_state", {
          method: "replication.run",
          state: "RUNNING",
        }),
      ).toBe(1)
      expect(
        find(samples, "truenas_job_last_finished_timestamp_seconds", {
          method: "replication.run",
        }),
      ).toHaveLength(0)
    })

    it("flags each task source that fails and keeps the rest", () => {
      const samples = collect({
        failing: ["cloudsync.query", "core.get_jobs"],
      })
      for (const source of ["tasks_cloudsync", "job_history"]) {
        expect(valueOf(samples, "truenas_health_collect_ok", { source })).toBe(
          0,
        )
      }
      for (const source of [
        "tasks_replication",
        "tasks_snapshot",
        "tasks_rsync",
      ]) {
        expect(valueOf(samples, "truenas_health_collect_ok", { source })).toBe(
          1,
        )
      }
      expect(
        find(samples, "truenas_task_state", { type: "cloudsync" }),
      ).toHaveLength(0)
      expect(
        find(samples, "truenas_task_state", { type: "snapshot" }),
      ).not.toHaveLength(0)
      expect(valueOf(samples, "truenas_pool_state", { pool: "tank" })).toBe(1)
    })
  })

  describe("cron schedules", () => {
    // Loads the script as a module and asks when a schedule last fired, with a
    // fixed local time zone, so the answer does not depend on the machine.
    const lastScheduled = (
      schedule: Record<string, string>,
      at: string,
    ): string | null => {
      const code = `
import datetime, importlib.util, json, os, sys, time
os.environ["TZ"] = "UTC"
time.tzset()
spec = importlib.util.spec_from_file_location("health", ${JSON.stringify(script)})
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)
result = health.last_scheduled(json.loads(sys.argv[1]), datetime.datetime.fromisoformat(sys.argv[2]))
print(datetime.datetime.utcfromtimestamp(result).isoformat() if result else "none")
`
      const result = spawnSync(
        "python3",
        ["-c", code, JSON.stringify(schedule), at],
        { encoding: "utf8" },
      )
      expect(result.stderr).toBe("")
      expect(result.status).toBe(0)
      const out = result.stdout.trim()
      return out === "none" ? null : out
    }
    const every = {
      minute: "*",
      hour: "*",
      dom: "*",
      month: "*",
      dow: "*",
    }

    it("finds the most recent run of a daily schedule", () => {
      const daily = { ...every, minute: "0", hour: "3" }
      expect(lastScheduled(daily, "2026-11-17T10:30:00")).toBe(
        "2026-11-17T03:00:00",
      )
      expect(lastScheduled(daily, "2026-11-17T02:59:00")).toBe(
        "2026-11-16T03:00:00",
      )
      expect(lastScheduled(daily, "2026-11-17T03:00:00")).toBe(
        "2026-11-17T03:00:00",
      )
    })

    it("handles steps, lists and ranges", () => {
      expect(
        lastScheduled({ ...every, minute: "*/15" }, "2026-11-17T10:32:10"),
      ).toBe("2026-11-17T10:30:00")
      expect(
        lastScheduled(
          { ...every, minute: "5,35", hour: "8-10" },
          "2026-11-17T12:00:00",
        ),
      ).toBe("2026-11-17T10:35:00")
      expect(
        lastScheduled(
          { ...every, minute: "0", hour: "*/6" },
          "2026-11-17T17:00:00",
        ),
      ).toBe("2026-11-17T12:00:00")
    })

    it("reads weekday names and numbers, with 0 and 7 both Sunday", () => {
      // 2026-11-17 is a Tuesday
      const at = "2026-11-17T12:00:00"
      const base = { ...every, minute: "30", hour: "2" }
      expect(lastScheduled({ ...base, dow: "sun" }, at)).toBe(
        "2026-11-15T02:30:00",
      )
      expect(lastScheduled({ ...base, dow: "7" }, at)).toBe(
        "2026-11-15T02:30:00",
      )
      expect(lastScheduled({ ...base, dow: "0" }, at)).toBe(
        "2026-11-15T02:30:00",
      )
      expect(lastScheduled({ ...base, dow: "mon-fri" }, at)).toBe(
        "2026-11-17T02:30:00",
      )
      expect(lastScheduled({ ...base, dow: "1,3" }, at)).toBe(
        "2026-11-16T02:30:00",
      )
    })

    it("reads months and days of the month, and either day field when both are set", () => {
      const at = "2026-11-17T12:00:00"
      const base = { ...every, minute: "0", hour: "0" }
      expect(lastScheduled({ ...base, dom: "1" }, at)).toBe(
        "2026-11-01T00:00:00",
      )
      expect(lastScheduled({ ...base, dom: "1", month: "jan" }, at)).toBe(
        "2026-01-01T00:00:00",
      )
      expect(lastScheduled({ ...base, dom: "1", dow: "fri" }, at)).toBe(
        "2026-11-13T00:00:00",
      )
    })

    it("only fires inside a snapshot window", () => {
      const window = { ...every, minute: "0", begin: "08:00", end: "18:00" }
      expect(lastScheduled(window, "2026-11-17T23:00:00")).toBe(
        "2026-11-17T18:00:00",
      )
      expect(lastScheduled(window, "2026-11-17T06:00:00")).toBe(
        "2026-11-16T18:00:00",
      )
    })

    it("gives up on a schedule that never fires", () => {
      expect(
        lastScheduled(
          { ...every, minute: "0", hour: "0", dom: "31", month: "feb" },
          "2026-11-17T12:00:00",
        ),
      ).toBeNull()
    })

    it("rejects a field outside its range", () => {
      const result = spawnSync(
        "python3",
        [
          "-c",
          `
import importlib.util, datetime
spec = importlib.util.spec_from_file_location("health", ${JSON.stringify(script)})
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)
try:
    health.last_scheduled({"minute": "75"}, datetime.datetime(2026, 11, 17))
except ValueError:
    print("rejected")
`,
        ],
        { encoding: "utf8" },
      )
      expect(result.stdout.trim()).toBe("rejected")
    })
  })

  describe("a failing source", () => {
    it("flags a pool.query that fails and keeps reporting everything else", () => {
      const samples = collect({ failing: ["pool.query"] })
      expect(
        valueOf(samples, "truenas_health_collect_ok", { source: "pool" }),
      ).toBe(0)
      expect(
        valueOf(samples, "truenas_health_collect_ok", { source: "boot_pool" }),
      ).toBe(1)
      expect(
        find(samples, "truenas_pool_state", { pool: "tank" }),
      ).toHaveLength(0)
      expect(
        valueOf(samples, "truenas_pool_state", { pool: "boot-pool" }),
      ).toBe(1)
      expect(find(samples, "truenas_smart_healthy")).toHaveLength(13)
      expect(samples[samples.length - 1].name).toBe(
        "truenas_health_push_timestamp_seconds",
      )
    })

    it("flags a boot.get_state that fails", () => {
      const samples = collect({ failing: ["boot.get_state"] })
      expect(
        valueOf(samples, "truenas_health_collect_ok", { source: "boot_pool" }),
      ).toBe(0)
      expect(
        valueOf(samples, "truenas_health_collect_ok", { source: "pool" }),
      ).toBe(1)
    })

    it("flags a disk.query that fails, and still reports the pools", () => {
      const samples = collect({ failing: ["disk.query"] })
      expect(
        valueOf(samples, "truenas_health_collect_ok", { source: "disks" }),
      ).toBe(0)
      expect(find(samples, "truenas_smart_healthy")).toHaveLength(0)
      expect(
        valueOf(samples, "truenas_pool_state", {
          pool: "tank",
          state: "ONLINE",
        }),
      ).toBe(1)
      const disk = find(samples, "truenas_pool_vdev_state", {
        pool: "tank",
        type: "DISK",
      })[0]
      expect(disk.labels.disk).toBe("sda")
      expect(disk.labels.serial).toBeUndefined()
    })
  })

  it("escapes quotes and backslashes in label values", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "truenas-health-"))
    tmpDirs.push(dir)
    const disks = path.join(dir, "disks.json")
    fs.writeFileSync(
      disks,
      JSON.stringify([
        { name: "sda", serial: 'A"B\\C', model: "Model\nTwo", type: "HDD" },
      ]),
    )
    const env = stubs({ failing: ["pool.query", "boot.get_state"] })
    fs.writeFileSync(
      path.join((env.PATH ?? "").split(":")[0], "midclt"),
      `#!/bin/sh\ncase "$2" in\n  disk.query) cat '${disks}';;\n  *) exit 1;;\nesac\n`,
      { mode: 0o755 },
    )
    const result = spawnSync("python3", [script, "print"], {
      env,
      encoding: "utf8",
    })
    expect(result.stdout).toContain(
      'truenas_disk_info{disk="sda",model="Model\\nTwo",serial="A\\"B\\\\C",type="HDD"} 1',
    )
  })

  describe("push", () => {
    const serve = async (
      status: number,
      onRequest: (request: {
        method?: string
        url?: string
        body: string
      }) => void,
    ) => {
      const server = http.createServer((request, response) => {
        let body = ""
        request.on("data", (chunk) => (body += chunk))
        request.on("end", () => {
          onRequest({ method: request.method, url: request.url, body })
          response.writeHead(status).end()
        })
      })
      await new Promise<void>((resolve) =>
        server.listen(0, "127.0.0.1", resolve),
      )
      const { port } = server.address() as { port: number }
      return { server, port }
    }

    it("POSTs the metrics to the import URL", async () => {
      const requests: { method?: string; url?: string; body: string }[] = []
      const { server, port } = await serve(204, (request) =>
        requests.push(request),
      )
      try {
        const url = `http://127.0.0.1:${port}/api/v1/import/prometheus`
        await execFileAsync("python3", [script, "push", url], { env: stubs() })
        expect(requests).toHaveLength(1)
        expect(requests[0].method).toBe("POST")
        expect(requests[0].url).toBe("/api/v1/import/prometheus")
        const samples = parse(requests[0].body)
        expect(valueOf(samples, "truenas_pool_state", { pool: "tank" })).toBe(1)
        expect(samples[samples.length - 1].name).toBe(
          "truenas_health_push_timestamp_seconds",
        )
      } finally {
        server.close()
      }
    })

    it("exits non-zero when VictoriaMetrics rejects the push", async () => {
      const { server, port } = await serve(500, () => undefined)
      try {
        await expect(
          execFileAsync(
            "python3",
            [script, "push", `http://127.0.0.1:${port}/x`],
            { env: stubs() },
          ),
        ).rejects.toMatchObject({ code: 1 })
      } finally {
        server.close()
      }
    })

    it("exits non-zero when nothing is listening", async () => {
      await expect(
        execFileAsync("python3", [script, "push", "http://127.0.0.1:1/x"], {
          env: stubs(),
        }),
      ).rejects.toMatchObject({ code: 1 })
    })
  })

  it("prints the usage and exits 2 when called wrong", () => {
    for (const args of [[], ["bogus"], ["push"]]) {
      const result = spawnSync("python3", [script, ...args], {
        env: stubs(),
        encoding: "utf8",
      })
      expect(result.status).toBe(2)
      expect(result.stderr).toContain("python3 truenas-health.py print")
    }
  })
})
