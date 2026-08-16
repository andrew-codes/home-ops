import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
  context,
): Promise<void> => {
  const env = await configurationApi.get("env")
  const ip = (await configurationApi.get("k8s/ip")).value
  const hostname = `${env}-k8s`

  await runPlaybook(
    path.join(__dirname, "..", "src", "deployment", "deploy-upgrade.yml"),
    [ip],
    { hostname },
  )
}

export default run
