import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import path from "path"
import { buildDnsHosts, isMissingKeyError } from "../src/dns-hosts"

// Sets only `dns.hosts` on both Pi-hole instances in one run. It does not
// touch the install, blocklists or gravity, unlike the deploy target.
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  let gatewayIp: string
  try {
    gatewayIp = await configurationApi.get("home-gateway/ip")
  } catch (error) {
    if (isMissingKeyError(error)) {
      logger.info(
        "The 1Password key home-gateway/ip does not exist. Nothing to do: no DNS records were changed.",
      )
      return
    }
    throw error
  }
  if (!gatewayIp.trim()) {
    logger.info(
      "The 1Password key home-gateway/ip is empty. Nothing to do: no DNS records were changed.",
    )
    return
  }

  const dnsHosts = buildDnsHosts(gatewayIp)
  logger.info(`Setting ${dnsHosts.length} dns.hosts records on both Pi-holes`)

  const ip = await configurationApi.get("pihole/ip")
  const ip2 = await configurationApi.get("pihole2/ip")

  await runPlaybook(
    path.join(__dirname, "..", "src", "dns-records", "index.yml"),
    [ip, ip2],
    { dnsHosts },
  )
}

export default run
