import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import * as terraform from "@ha/terraform"
import path from "path"
import { v4 as uuid } from "uuid"
import deploy from "./deploy"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Provisioning Pi-hole")
  const ip1 = await configurationApi.get("tailscale/ip")
  const gateway = await configurationApi.get("unifi/ip")
  const pveHost = await configurationApi.get("proxmox/host/pve")
  const pmUsername = await configurationApi.get("proxmox/username")
  const pmPassword = await configurationApi.get("proxmox/password")
  const hostname = `tailscale-${uuid()}`
  const nameserver = await configurationApi.get("proxmox/nameserver")

  const proxmoxSshKey = await configurationApi.get("proxmox/ssh-key/public")
  const devSshKey = await configurationApi.get("dev/ssh-key/public")
  const haSshKey = await configurationApi.get("home-assistant/ssh-key/public")

  const sshKey = [proxmoxSshKey, devSshKey, haSshKey].join("\n")

  const vmId = ip1.split(".").slice(1).join("")

  var vars = {
    ip: `${ip1}/8`,
    gateway,
    pmApiUrl: `https://${pveHost}/api2/json`,
    pmUsername,
    pmPassword,
    sshKey,
    hostname,
    nameserver,
    vmId,
  }

  await terraform.apply(
    vars,
    path.join(__dirname, "..", "src", "provision"),
    path.join(__dirname, "..", ".terraform"),
  )

  const proxmoxIp = await configurationApi.get("proxmox/ip")
  await runPlaybook(
    path.join(__dirname, "..", "src", "provision", "provision.yml"),
    [proxmoxIp],
    {
      vmId,
    },
  )

  await deploy(configurationApi)
}

export default run
