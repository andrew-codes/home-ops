import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Updating Pi-hole")
  const ip = await configurationApi.get("pihole/ip")
  const ip2 = await configurationApi.get("pihole2/ip")

  const updatePath = path.join(__dirname, "..", "src", "update")
  await runPlaybook(path.join(updatePath, "index.yml"), [ip, ip2])
}

export default run
