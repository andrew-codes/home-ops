import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import { env } from "node:process"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying pve host configuration")

  const proxmoxIp = await configurationApi.get("proxmox/ip")
  const captainSshPublicKey = await configurationApi.get(
    "andrew-mbp/public-key",
  )
  const nasHost = await configurationApi.get("nas/ip")
  const nasIsoUsername = await configurationApi.get("pve-nas-iso/username")
  const nasIsoPassword = await configurationApi.get("pve-nas-iso/password")
  const pbsUsername = await configurationApi.get("pve-pbs/username")
  const pbsPassword = await configurationApi.get("pve-pbs/password")

  // Not yet in 1Password - see README "Proxmox Backup Server integration".
  const pbsFingerprint = env["PBS_FINGERPRINT"] ?? ""

  const deployPath = path.join(__dirname, "..", "src", "deploy")
  await runPlaybook(path.join(deployPath, "index.yml"), [proxmoxIp], {
    ip: "10.1.0.100/24",
    gateway: "10.1.0.1",
    dns_servers: ["1.1.1.1", "1.0.0.1"],
    search_domain: "smith-simms.family",
    captain_ssh_public_key: captainSshPublicKey,
    nas_iso_host: nasHost,
    nas_iso_username: nasIsoUsername,
    nas_iso_password: nasIsoPassword,
    pbs_host: "10.0.209.71",
    pbs_datastore: "nas",
    pbs_username: pbsUsername,
    pbs_password: pbsPassword,
    pbs_fingerprint: pbsFingerprint,
  })
}

export default run
