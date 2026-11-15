import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

/**
 * Sends logs and metrics from every Proxmox VE host to the cluster, without
 * running the host-specific steps of `deploy` (network, storage, GPU, NUT).
 * `deploy` runs the same tasks for the first host; use this target for a host
 * the full playbook does not manage.
 */
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying pve observability configuration")

  const observabilityHost = await configurationApi.get("k8s/ip")
  const hosts = [await configurationApi.get("proxmox/ip")]

  try {
    hosts.push(await configurationApi.get("proxmox2/ip"))
  } catch (error) {
    logger.warn(
      "proxmox2/ip is not set in 1Password; configuring the first host only.",
    )
    logger.warn(error)
  }

  const playbook = path.join(
    __dirname,
    "..",
    "src",
    "deploy",
    "observability.yml",
  )
  await runPlaybook(playbook, hosts, {
    observability_host: observabilityHost,
  })
}

export default run
