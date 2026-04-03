import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const ip = (await configurationApi.get("openclaw/ip")).value

  await runPlaybook(
    path.join(__dirname, "..", "src", "deployment", "deploy.yml"),
    [ip],
    {},
  )
}

export default run
