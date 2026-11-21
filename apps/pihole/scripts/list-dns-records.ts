import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

// Read-only. Prints dns.hosts from both Pi-holes and fails when they differ.
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Listing dns.hosts on both Pi-holes")
  const ip = await configurationApi.get("pihole/ip")
  const ip2 = await configurationApi.get("pihole2/ip")

  await runPlaybook(
    path.join(__dirname, "..", "src", "dns-records-list", "index.yml"),
    [ip, ip2],
  )
}

export default run
