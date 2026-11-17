import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

/**
 * Sends the logs of the Proxmox guests this repo manages to the cluster's
 * VictoriaLogs, without running anything else on them. The guests are the Pi-hole
 * containers, the Tailscale container and the Kubernetes node VM. The OpenClaw
 * container and any guest the repo does not manage (Home Assistant OS, for one)
 * need the same rsyslog forwarding by hand; see README.md#proxmox-guests.
 *
 * Run it again after provisioning a new guest, and add the guest's address here.
 */
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying guest observability configuration")

  const observabilityHost = await configurationApi.get("k8s/ip")
  const guests = [
    await configurationApi.get("pihole/ip"),
    await configurationApi.get("pihole2/ip"),
    await configurationApi.get("tailscale/ip"),
    observabilityHost,
  ]

  const playbook = path.join(
    __dirname,
    "..",
    "src",
    "deploy",
    "guest-observability.yml",
  )
  await runPlaybook(playbook, guests, {
    observability_host: observabilityHost,
  })
}

export default run
