import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  logger.info("Deploying Pi-hole")
  const ip = await configurationApi.get("pihole/ip")
  const ip2 = await configurationApi.get("pihole2/ip")
  const password = await configurationApi.get("pihole/password")
  const domain = await configurationApi.get("pihole/domain")
  const dhcpIp = await configurationApi.get("unifi/ip")
  const cidr = await configurationApi.get("tailscale/subnet-routes")

  const dnsEntries = []

  const deploymentPath = path.join(__dirname, "..", "src", "deployment")
  await runPlaybook(path.join(deploymentPath, "index.yml"), [ip, ip2], {
    pihole_password: password,
    domain,
    dhcpIp,
    cidr,
    dnsEntries: JSON.stringify(dnsEntries),
  })
}

export default run
