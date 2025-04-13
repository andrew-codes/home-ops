import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import fs from "fs/promises"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
  context,
): Promise<void> => {
  const env = await configurationApi.get("env")
  const ip = (await configurationApi.get("k8s/ip")).value

  const vars = {}
  await runPlaybook(
    path.join(
      __dirname,
      "..",
      "src",
      "deployment",
      "playbooks",
      "reset-k8s.yml",
    ),
    [ip],
    vars,
  )

  try {
    await fs.unlink(path.join(__dirname, `../._secrets/${env}/.kube/config`))
    configurationApi.set("k8s/config", "")
  } catch (e) {}
}

export default run
