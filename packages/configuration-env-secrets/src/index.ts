import { ConfigurationApi } from "@ha/configuration-api"
import { toEnvName } from "@ha/secret-utils"
import { env } from "node:process"

const createEnvConfigurationApi = <TSecretNames extends ReadonlyArray<string>>(
  secretNames: TSecretNames,
): ConfigurationApi<Record<TSecretNames[number], string>> => {
  return {
    get: async (name: TSecretNames[number]) => {
      const value = { ...env }[toEnvName(name)]
      if (!value) {
        throw new Error(`Configuration value ${name} not found.`)
      }

      return value
    },
    getNames: () => secretNames,
    set: async () => {
      throw new Error("Not implemented")
    },
  }
}

const provisionedSecretNames = [
  "dev/ssh-key/public",
  "env",
  "github/username",
  "github/token",
  "home-assistant/ssh-key/public",
  "k8s/ip",
  "k8s/pod-network-cidr",
  "pihole/domain",
  "pihole/hostname",
  "pihole/ip",
  "pihole/password",
  "pihole2/ip",
  "proxmox/host/pve",
  "proxmox/ip",
  "proxmox/nameserver",
  "proxmox/password",
  "proxmox/ssh-key/public",
  "proxmox/username",
  "tailscale/auth-key",
  "tailscale/ip",
  "tailscale/subnet-routes",
  "unifi/ip",
] as const
const provisionedEnvConfiguration = createEnvConfigurationApi(
  provisionedSecretNames,
)

const sealedSecretNames = [
  "mqtt-credentials/username",
  "mqtt-credentials/password",
  "grafana-admin/admin",
  "grafana-admin/admin-password",
  "mqtt-passwd/mqtt_passwd",
  "tunnel-credentials/credentials.json",
  "home-assistant-token/token",
  "playnite-web-credentials/username",
  "playnite-web-credentials/password",
  "psn-accounts/accounts",
] as const
const sealedSecretEnvConfiguration =
  createEnvConfigurationApi(sealedSecretNames)

export { provisionedEnvConfiguration, sealedSecretEnvConfiguration }
export default createEnvConfigurationApi
