import { execFile as execFileCb } from "child_process"
import fs from "fs/promises"
import path from "path"
import { promisify } from "util"
import sh from "shelljs"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { throwIfError } from "@ha/shell-utils"

const execFile = promisify(execFileCb)

/**
 * Andrew's personal SSH key lives in the "Private" 1Password vault as
 * the "andrew-mbp" item, independent of OP_VAULT (the shared infra-secrets
 * vault every other configurationApi.get() call reads from), so it is read
 * directly here rather than through configurationApi/secretNames.
 */
const getAndrewSshPublicKey = async (): Promise<string> => {
  const { stdout } = await execFile("op", [
    "read",
    "--no-newline",
    "op://Private/andrew-mbp/public key",
  ])
  return stdout
}

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  sh.env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
  sh.env["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES"
  const ip = await configurationApi.get("pbs/ip")
  const username = await configurationApi.get("pbs/username")
  const password = await configurationApi.get("pbs/password")
  const nasIp = await configurationApi.get("nas/ip")
  const backupUsername = await configurationApi.get("pbs/backup-username")
  const backupPassword = await configurationApi.get("pbs/backup-password")
  const nutMonitorUsername = await configurationApi.get("nut/monitor-username")
  const nutMonitorPassword = await configurationApi.get("nut/monitor-password")
  const andrewSshPublicKey = await getAndrewSshPublicKey()

  await fs.mkdir(path.join(__dirname, "..", ".secrets"), { recursive: true })

  await fs.writeFile(
    path.join(__dirname, "..", ".secrets", "hosts.yml"),
    `all:
  vars:
    ansible_user: ${username}
    ansible_password: ${password}
  hosts:
    ${ip}:
`,
    "utf8",
  )
  await fs.writeFile(
    path.join(__dirname, "..", ".secrets", "ansible-secrets.yml"),
    `---
nas_host: ${nasIp}
pbs_backup_username: ${backupUsername}
pbs_backup_password: ${backupPassword}
nut_monitor_username: ${JSON.stringify(nutMonitorUsername)}
nut_monitor_password: ${JSON.stringify(nutMonitorPassword)}
andrew_ssh_public_key: "${andrewSshPublicKey}"
`,
    "utf8",
  )

  await throwIfError(
    sh.exec(
      `ansible-playbook ${path.join(__dirname, "deploy.yml")} -i ${path.join(
        __dirname,
        "..",
        ".secrets",
        "hosts.yml",
      )};`,
      { silent: false },
    ),
  )
}

export default run
