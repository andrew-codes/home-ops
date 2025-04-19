import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying Tailscale")
  const ip = await configurationApi.get("tailscale/ip")
  const authKey = await configurationApi.get("tailscale/auth-key")
  const subnetRoutes = (
    await configurationApi.get("tailscale/subnet-routes")
  ).split(",")

  const deploymentPath = path.join(__dirname, "..", "src", "deployment")
  await runPlaybook(path.join(deploymentPath, "index.yml"), [ip], {
    hostname: "tailscale",
    subnetRoutes: subnetRoutes.join(","),
    authKey,
  })
}

export default run
