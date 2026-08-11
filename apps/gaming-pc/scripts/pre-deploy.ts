import { spawnSync } from "child_process"
import type { SpawnSyncReturns } from "child_process"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"

/**
 * Prepares both ends of `nx deploy gaming-pc`.
 *
 * The two halves are deliberately not treated the same way:
 *
 * - The Mac half (Ansible plus the two Windows collections) is fully
 *   automated and idempotent. Anything already present is left exactly as it
 *   is; nothing is upgraded behind the operator's back.
 * - The Windows half cannot be automated from here without lying about it.
 *   That block is what *enables* SSH, so there is no SSH to run it over. It is
 *   emitted as a ready-to-paste block with the real public key already
 *   substituted, which removes the one genuinely error-prone step, and then
 *   the result is verified so the operator learns the prerequisites are
 *   satisfied before running a deploy rather than watching one fail.
 *
 * Running the block over WinRM was considered and rejected. WinRM does happen
 * to be enabled on this particular machine because `apps/backups` targets it,
 * but it is absent on any fresh Windows install, so it could only ever be an
 * opportunistic fast path sitting beside the paste block - a second transport,
 * its own credentials and its own failure modes, for a step taken once per
 * machine. The paste block covers every machine with one mechanism.
 *
 * Output goes to the console rather than `@ha/logger`: this is an operator
 * report containing a block meant to be copied verbatim, and the logger's
 * `simple` format prefixes every line with its log level.
 */

const REQUIRED_COLLECTIONS = ["ansible.windows", "community.windows"] as const

const POWERSHELL_DEFAULT_SHELL =
  "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"

type Capture = SpawnSyncReturns<string>

const capture = (command: string, args: string[]): Capture =>
  spawnSync(command, args, { encoding: "utf8" })

const isMissingExecutable = (result: Capture): boolean =>
  (result.error as NodeJS.ErrnoException | undefined)?.code === "ENOENT"

const succeeded = (result: Capture): boolean =>
  !result.error && result.status === 0

const runInteractively = (command: string, args: string[]): void => {
  const result = spawnSync(command, args, { stdio: "inherit" })
  if (result.error) {
    throw result.error
  }
  if (result.status !== 0) {
    throw new Error(
      `\`${command} ${args.join(" ")}\` exited with code ${result.status}`,
    )
  }
}

const ansibleVersion = (): string | undefined => {
  const result = capture("ansible", ["--version"])
  if (!succeeded(result)) {
    return undefined
  }
  return result.stdout.split("\n")[0].trim()
}

/**
 * Installs Ansible through Homebrew, which is where it already lives on the
 * machines this repo manages, and deliberately not through `pip`. A global
 * `pip install` mutates whichever Python happens to be first on PATH, and on a
 * Homebrew Python that install is refused outright (PEP 668). Homebrew keeps
 * Ansible and its interpreter self-contained.
 */
const ensureAnsible = (): string => {
  const existing = ansibleVersion()
  if (existing) {
    return `already installed (${existing})`
  }

  if (isMissingExecutable(capture("brew", ["--version"]))) {
    throw new Error(
      "Ansible is not installed and Homebrew is not available to install it. " +
        "Install Ansible manually (`brew install ansible`, or a pipx/virtualenv " +
        "install of your choosing) and re-run this target.",
    )
  }

  console.log("  installing Ansible via Homebrew...")
  runInteractively("brew", ["install", "ansible"])

  const installed = ansibleVersion()
  if (!installed) {
    throw new Error(
      "Homebrew reported success but `ansible` is still not on PATH.",
    )
  }
  return `installed (${installed})`
}

const installedCollectionVersion = (name: string): string | undefined => {
  const result = capture("ansible-galaxy", [
    "collection",
    "list",
    name,
    "--format",
    "json",
  ])
  if (!succeeded(result)) {
    return undefined
  }
  try {
    const byPath = JSON.parse(result.stdout) as Record<
      string,
      Record<string, { version?: string }>
    >
    const found = Object.values(byPath)
      .map((collections) => collections[name])
      .find(Boolean)
    return found?.version ?? undefined
  } catch {
    // A parse failure only costs the "already present" shortcut. The install
    // below is itself idempotent, so falling through is safe.
    return undefined
  }
}

/**
 * `ansible-galaxy collection install` without `--force`/`--upgrade` is a no-op
 * on an already-installed collection, so an existing install is never
 * silently upgraded even if the check above cannot see it.
 */
const ensureCollection = (name: string): string => {
  const existing = installedCollectionVersion(name)
  if (existing) {
    return `already installed (${existing})`
  }

  console.log(`  installing ${name}...`)
  runInteractively("ansible-galaxy", ["collection", "install", name])

  const installed = installedCollectionVersion(name)
  return installed ? `installed (${installed})` : "installed"
}

const windowsPrerequisiteBlock = (publicKey: string): string =>
  `# Install the OpenSSH server that ships with Windows.
Get-WindowsCapability -Online -Name OpenSSH.Server* | Add-WindowsCapability -Online

# Start it now and on every boot.
Set-Service -Name sshd -StartupType Automatic -Status Running

# Ansible drives Windows through PowerShell, not cmd.
New-ItemProperty -Path HKLM:\\SOFTWARE\\OpenSSH -Name DefaultShell \`
  -Value ${POWERSHELL_DEFAULT_SHELL} \`
  -PropertyType String -Force

# Authorize this Mac's public key. Until the playbook installs its own
# sshd_config, administrators share one key file.
$key = '${publicKey.trim()}'
$adminKeys = "$env:ProgramData\\ssh\\administrators_authorized_keys"
if (-not (Select-String -Path $adminKeys -SimpleMatch $key -ErrorAction SilentlyContinue)) {
  Add-Content -Path $adminKeys -Value $key
}
icacls $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'`

interface Reachability {
  readonly satisfied: boolean
  readonly summary: string
  readonly remedy?: string
}

/**
 * Asks the machine over SSH for the one registry value the transport depends
 * on. `reg query` is chosen because it answers identically whether the SSH
 * session lands in cmd or in PowerShell, which is exactly the thing under
 * test.
 */
const checkWindowsPrerequisites = (
  username: string,
  host: string,
  redact: (text: string) => string,
): Reachability => {
  const result = capture("ssh", [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "StrictHostKeyChecking=accept-new",
    `${username}@${host}`,
    "reg query HKLM\\SOFTWARE\\OpenSSH /v DefaultShell",
  ])

  if (isMissingExecutable(result)) {
    return {
      satisfied: false,
      summary: "`ssh` is not on PATH, so reachability could not be checked.",
    }
  }

  if (result.status === 255) {
    const stderr = redact(result.stderr).trim()
    const deniedKey = /permission denied|no supported authentication/i.test(
      stderr,
    )
    return {
      satisfied: false,
      summary: deniedKey
        ? "SSH answered but refused this Mac's key."
        : "SSH did not answer.",
      remedy: deniedKey
        ? `The sshd service is running, so only the authorized-keys and icacls\n` +
          `lines of the block below still need to run.\n\n${stderr}`
        : `Either the OpenSSH server is not installed or running, or the\n` +
          `machine is off or on a different address than 1Password's\n` +
          `\`gaming-pc/ip\`. Run the whole block below.\n\n${stderr}`,
    }
  }

  if (!succeeded(result)) {
    return {
      satisfied: false,
      summary:
        "SSH authenticated, but the DefaultShell registry value is not set.",
      remedy:
        "Ansible would land in cmd while the generated inventory declares\n" +
        "`ansible_shell_type: powershell`, and every task would fail. Run the\n" +
        "`New-ItemProperty ... DefaultShell` line of the block below.",
    }
  }

  if (!result.stdout.toLowerCase().includes("powershell.exe")) {
    return {
      satisfied: false,
      summary: `SSH authenticated, but DefaultShell does not point at PowerShell.`,
      remedy:
        "Re-run the `New-ItemProperty ... DefaultShell` line of the block\n" +
        `below so it reads ${POWERSHELL_DEFAULT_SHELL}.`,
    }
  }

  return {
    satisfied: true,
    summary:
      "SSH answers, this Mac's key authenticates, DefaultShell is PowerShell.",
  }
}

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  console.log("\nMac prerequisites")
  console.log(`  ansible: ${ensureAnsible()}`)
  for (const collection of REQUIRED_COLLECTIONS) {
    console.log(`  ${collection}: ${ensureCollection(collection)}`)
  }

  const publicKey = await configurationApi.get("dev/ssh-key/public")
  const host = await configurationApi.get("gaming-pc/ip")
  const username = await configurationApi.get("gaming-pc/username")

  // The address and the account name come from 1Password and stay out of the
  // report; only the public key, which is public by construction and has to be
  // pasted onto the machine, is printed.
  const redact = (text: string): string =>
    text
      .split(host)
      .join("<gaming-pc/ip>")
      .split(username)
      .join("<gaming-pc/username>")

  const windows = checkWindowsPrerequisites(username, host, redact)

  console.log("\nWindows prerequisites (checked over SSH)")
  console.log(`  ${windows.summary}`)

  if (windows.satisfied) {
    console.log(
      "\nNothing left to do by hand. Run `yarn nx deploy gaming-pc`.\n",
    )
    return
  }

  console.log(
    `\n${windows.remedy}\n\n` +
      "This part cannot be automated from here: the block below is what\n" +
      "enables SSH, so there is no SSH to run it over. Open an Administrator\n" +
      "PowerShell **on the gaming PC** and paste it. It is safe to re-run, it\n" +
      "downloads nothing, and it needs no reboot. This Mac's public key is\n" +
      "already filled in.\n\n" +
      "If the machine was provisioned before this repo moved to SSH, run\n" +
      "`choco uninstall openssh -y` first: the Chocolatey package registers a\n" +
      "competing sshd from a different OpenSSH build.\n",
  )
  console.log(
    "-------------------------- copy from here --------------------------",
  )
  console.log(windowsPrerequisiteBlock(publicKey))
  console.log(
    "--------------------------- to here --------------------------------\n",
  )
  console.log(
    "Then confirm the machine has a static IP, or that 1Password's\n" +
      "`gaming-pc/ip` still matches its current one, and re-run this target to\n" +
      "verify before deploying.\n",
  )

  throw new Error(
    "Windows prerequisites are not satisfied yet. Follow the steps printed above, then re-run `yarn nx pre-deploy gaming-pc`.",
  )
}

export default run
