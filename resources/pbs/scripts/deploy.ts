import fs from "fs/promises"
import path from "path"
import sh from "shelljs"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { throwIfError } from "@ha/shell-utils"

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
`,
    "utf8",
  )

  await throwIfError(
    sh.exec(
      `ansible-playbook ${path.join(
        __dirname,
        "deploy.yml",
      )} -i ${path.join(
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
