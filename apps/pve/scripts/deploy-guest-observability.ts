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
 * Run it again after provisioning a new guest, and add the guest's address and display name to `guestNames` here.
 */
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying guest observability configuration")

  const observabilityHost = await configurationApi.get("k8s/ip")
  // Each guest's logs are stamped with this display name instead of its OS
  // hostname, which can be localhost or blank. The OS hostnames are not changed.
  const guestNames: Record<string, string> = {
    [await configurationApi.get("pihole/ip")]: "pihole-1",
    [await configurationApi.get("pihole2/ip")]: "pihole-2",
    [await configurationApi.get("tailscale/ip")]: "tailscale",
    [observabilityHost]: "k8s-node",
  }
  const guests = Object.keys(guestNames)

  const playbook = path.join(
    __dirname,
    "..",
    "src",
    "deploy",
    "guest-observability.yml",
  )
  await runPlaybook(playbook, guests, {
    observability_host: observabilityHost,
    observability_guest_names: guestNames,
  })
}

export default run
