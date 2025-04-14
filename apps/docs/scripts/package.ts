import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import createClient from "@ha/docker"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const docker = await createClient(configurationApi)
  await docker.build(`home-ops-docs:latest`, {
    context: path.join(__dirname, "../"),
    dockerFile: path.join("src", "Dockerfile"),
  })
}

export default run
