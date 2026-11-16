import { logger } from "@ha/logger"
import { throwIfError } from "@ha/shell-utils"
import sh from "shelljs"

// Pinned so Ansible does not warn on every run that a later-installed Python
// could change the discovered interpreter. /usr/bin/python3 is the stable
// link on Debian and Ubuntu based hosts. A caller can still override it.
const defaultVars: Record<string, any> = {
  ansible_python_interpreter: "/usr/bin/python3",
}

const buildPlaybookCommand = (
  playbookPath: string,
  hosts: Array<string>,
  vars?: Record<string, any> | undefined,
  privateKeyPath?: string | undefined,
): string =>
  `ansible-playbook --inventory "${hosts.join(
    ",",
  )}," --extra-vars '${JSON.stringify({ ...defaultVars, ...vars })}' ${privateKeyPath ? `--private-key ${privateKeyPath}` : ""} ${playbookPath};`

const runPlaybook = async (
  playbookPath: string,
  hosts: Array<string>,
  vars?: Record<string, any> | undefined,
  privateKeyPath?: string | undefined,
): Promise<void> => {
  sh.env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
  sh.env["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES"

  logger.info(`Running playbook ${playbookPath} on hosts ${hosts.join(",")}`)
  await throwIfError(
    sh.exec(buildPlaybookCommand(playbookPath, hosts, vars, privateKeyPath), {
      async: true,
      silent: false,
    }),
  )
}

export { buildPlaybookCommand, runPlaybook }
