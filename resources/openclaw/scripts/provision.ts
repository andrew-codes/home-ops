import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import * as terraform from "@ha/terraform"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const pveHost = await configurationApi.get("proxmox/host/pve")
  const pmUser = await configurationApi.get("proxmox/username")
  const pmPassword = await configurationApi.get("proxmox/password")
  const proxmoxSshKey = await configurationApi.get("proxmox/ssh-key/public")
  const devSshKey = await configurationApi.get("dev/ssh-key/public")
  const sshKeys = [proxmoxSshKey, devSshKey].join("\n")
  const nameserver = await configurationApi.get("proxmox/nameserver")
  const gateway = await configurationApi.get("unifi/ip")

  await terraform.apply(
    {
      pmApiUrl: `https://${pveHost}/api2/json`,
      pmUser,
      pmPassword,
      vmId: 20150,
      ostemplate: "nas-iso:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst",
      sshKeys,
      ip: "10.2.0.150/24",
      gateway,
      nameserver,
    },
    path.join(__dirname, "..", "src", "provision"),
    path.join(__dirname, "..", ".terraform"),
  )
}

export default run
