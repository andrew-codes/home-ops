import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

/**
 * Sends TrueNAS metrics (Graphite exporter) and logs (remote syslog) to the
 * cluster. The TrueNAS address and SSH user are optional: when either is not
 * in 1Password yet, this logs a warning and does nothing. truenas/health-dir
 * is required once those two are set.
 */
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying TrueNAS observability configuration")

  let truenasIp: string
  let truenasUsername: string
  try {
    truenasIp = await configurationApi.get("truenas/ip")
    truenasUsername = await configurationApi.get("truenas/username")
  } catch (error) {
    logger.warn(
      "truenas/ip or truenas/username is not set in 1Password; nothing to configure.",
    )
    logger.warn(error)
    return
  }
  const observabilityHost = await configurationApi.get("k8s/ip")
  // Directory on a pool dataset (under /mnt) that holds the health collector.
  // Required: the cron job's command is capped at 1024 characters, so it
  // cannot carry the script.
  const healthDir = await configurationApi.get("truenas/health-dir")

  const playbook = path.join(__dirname, "..", "src", "deploy", "index.yml")
  await runPlaybook(playbook, [truenasIp], {
    ansible_user: truenasUsername,
    observability_host: observabilityHost,
    health_dir: healthDir,
  })
}

export default run
