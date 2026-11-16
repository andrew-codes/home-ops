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
  const sshPublicKey = await configurationApi.get("andrew-mbp/public-key")
  const nasHost = await configurationApi.get("nas/ip")
  const nasIsoUsername = await configurationApi.get("pve-nas-iso/username")
  const nasIsoPassword = await configurationApi.get("pve-nas-iso/password")
  const pbsHost = await configurationApi.get("pbs/ip")
  const pbsUsername = await configurationApi.get("pbs/backup-username")
  const pbsPassword = await configurationApi.get("pbs/backup-password")
  const nutMonitorUsername = await configurationApi.get("nut/monitor-username")
  const nutMonitorPassword = await configurationApi.get("nut/monitor-password")
  const observabilityHost = await configurationApi.get("k8s/ip")

  // Not in 1Password - see README "PBS TLS fingerprint".
  const pbsFingerprint = env["PBS_FINGERPRINT"] ?? ""

  const deployPath = path.join(__dirname, "..", "src", "deploy")
  await runPlaybook(path.join(deployPath, "index.yml"), [proxmoxIp], {
    ip: "10.1.0.100/24",
    gateway: "10.1.0.1",
    dns_servers: ["1.1.1.1", "1.0.0.1"],
    search_domain: "smith-simms.family",
    ssh_public_key: sshPublicKey,
    nas_iso_host: nasHost,
    nas_iso_username: nasIsoUsername,
    nas_iso_password: nasIsoPassword,
    pbs_host: pbsHost,
    pbs_datastore: "main",
    pbs_username: pbsUsername,
    pbs_password: pbsPassword,
    pbs_fingerprint: pbsFingerprint,
    nut_server_host: "10.5.113.53",
    nut_server_port: 3493,
    nut_ups_name: "ups",
    nut_monitor_username: nutMonitorUsername,
    nut_monitor_password: nutMonitorPassword,
    observability_host: observabilityHost,
  })
}

export default run
