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
  const ip = await configurationApi.get("gaming-pc/ip")
  const user = await configurationApi.get("gaming-pc/user")
  const username = await configurationApi.get("gaming-pc/username")
  const password = await configurationApi.get("gaming-pc/password")
  const andrewPassword = await configurationApi.get("gaming-pc/andrew-password")
  const haSshPub = await configurationApi.get("home-assistant/ssh-key-public")
  const devSshPub = await configurationApi.get("dev/ssh-key/public")

  await fs.mkdir(path.join(__dirname, "..", ".secrets"), { recursive: true })

  // Transport lives here, not in the playbook, so the playbook stays connection
  // agnostic. Ansible reaches Windows over the OpenSSH server that ships with
  // Windows; ansible_shell_type must match the host's DefaultShell registry
  // value, which the playbook pins to powershell.exe.
  await fs.writeFile(
    path.join(__dirname, "..", ".secrets", "hosts.yml"),
    `all:
  vars:
    ansible_user: ${username}
    ansible_connection: ssh
    ansible_shell_type: powershell
    ansible_port: 22
  hosts:
    ${ip}:
`,
    "utf8",
  )
  // The Windows account password is no longer the transport credential, but the
  // playbook still needs it to elevate (become/runas) and to configure
  // auto-login, so it is passed as a plain play variable.
  await fs.writeFile(
    path.join(__dirname, "..", ".secrets", "ansible-secrets.yml"),
    `---
user: ${JSON.stringify(user)}
andrew_password: ${JSON.stringify(andrewPassword)}
windows_password: ${JSON.stringify(password)}
`,
    "utf8",
  )
  await fs.writeFile(
    path.join(__dirname, "..", ".secrets", "authorized_keys"),
    `${haSshPub}
${devSshPub}`,
    "utf8",
  )

  await throwIfError(
    sh.exec(
      `ansible-playbook ${path.join(__dirname, "provision.yml")} -i ${path.join(
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
