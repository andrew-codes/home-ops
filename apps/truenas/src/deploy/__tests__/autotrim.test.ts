import { spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const tasks = path.join(__dirname, "..", "tasks", "autotrim.yml")
const fixtures = path.join(__dirname, "fixtures")

const tmpDirs: string[] = []

afterAll(() => {
  tmpDirs.forEach((dir) => fs.rmSync(dir, { recursive: true, force: true }))
})

type Result = {
  status: number | null
  output: string
  // every `midclt call` the play made, one line per call
  calls: string[]
}

// Runs tasks/autotrim.yml against a stand-in midclt that prints the recorded
// fixtures and logs every call, so the play runs exactly as it does on the NAS
// except that nothing is written. Needs ansible-playbook.
const runPlay = (pools: string, disks = "disks"): Result => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "truenas-autotrim-"))
  tmpDirs.push(dir)
  const bin = path.join(dir, "bin")
  fs.mkdirSync(bin)
  const log = path.join(dir, "calls.log")
  fs.writeFileSync(
    path.join(bin, "midclt"),
    `#!/bin/sh
[ "$1" = call ] || exit 2
shift
[ "$1" = -job ] && { job=1; shift; }
echo "$*" >> '${log}'
case "$1" in
  pool.query) cat '${path.join(fixtures, `${pools}.json`)}' ;;
  disk.query) cat '${path.join(fixtures, `${disks}.json`)}' ;;
  pool.update) [ -n "$job" ] || { echo "pool.update needs -job" >&2; exit 1; }; echo '{}' ;;
  *) echo "unexpected midclt call: $*" >&2; exit 1 ;;
esac
`,
    { mode: 0o755 },
  )
  const playbook = path.join(dir, "play.yml")
  fs.writeFileSync(
    playbook,
    `---
- hosts: localhost
  gather_facts: no
  connection: local
  tasks:
    - ansible.builtin.import_tasks: ${tasks}
`,
  )
  const result = spawnSync("ansible-playbook", [playbook], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      ANSIBLE_NOCOLOR: "1",
      ANSIBLE_HOME: path.join(dir, "ansible-home"),
      ANSIBLE_LOCAL_TEMP: path.join(dir, "tmp"),
    },
  })
  const calls = fs.existsSync(log)
    ? fs.readFileSync(log, "utf8").trim().split("\n")
    : []
  return {
    status: result.status,
    output: `${result.stdout}${result.stderr}`,
    calls,
  }
}

const updates = (calls: string[]): string[] =>
  calls.filter((call) => call.startsWith("pool.update"))

describe("autotrim tasks", () => {
  it("enables autotrim on the SSD mirror and leaves the HDD pool alone", () => {
    const result = runPlay("pools_off")

    expect(result.status).toBe(0)
    expect(updates(result.calls)).toEqual(['pool.update 1 {"autotrim": "ON"}'])
    expect(result.output).toContain("fast: autotrim enabled")
    expect(result.output).toContain("tank: not an SSD pool (HDD), unchanged")
    expect(result.output).toMatch(/changed=1\b/)
  })

  it("changes nothing when the SSD pool already has autotrim on", () => {
    const result = runPlay("pools_ssd_on")

    expect(result.status).toBe(0)
    expect(updates(result.calls)).toEqual([])
    expect(result.output).toContain("fast: autotrim already on, unchanged")
    expect(result.output).toContain("tank: not an SSD pool (HDD), unchanged")
    expect(result.output).toMatch(/changed=0\b/)
  })

  it("skips a pool that mixes an SSD and an HDD", () => {
    const result = runPlay("pools_mixed")

    expect(result.status).toBe(0)
    expect(updates(result.calls)).toEqual([])
    expect(result.output).toContain("fast: not an SSD pool (HDD, SSD)")
  })

  it("skips a pool whose disk the middleware does not list", () => {
    const result = runPlay("pools_off", "disks_missing_sdi")

    expect(result.status).toBe(0)
    expect(updates(result.calls)).toEqual([])
    expect(result.output).toContain("fast: not an SSD pool (SSD, UNKNOWN)")
  })
})
