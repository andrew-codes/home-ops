import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

/**
 * Sends the Pi-hole query log (pihole.log) and FTL log (FTL.log) to the
 * cluster's VictoriaLogs and installs node_exporter for the host metrics, on both
 * Pi-holes. It does not change Pi-hole's configuration and does not need its
 * password, so it can run on its own after the Pi-holes exist. The Pi-hole
 * metrics and the DNS probe run in the cluster and need nothing here.
 */
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying Pi-hole observability")
  const ip = await configurationApi.get("pihole/ip")
  const ip2 = await configurationApi.get("pihole2/ip")
  const observabilityHost = await configurationApi.get("k8s/ip")

  await runPlaybook(
    path.join(__dirname, "..", "src", "observability", "index.yml"),
    [ip, ip2],
    { observability_host: observabilityHost },
  )
}

export default run
