import { createConfigurationApi } from '@ha/configuration-aggregate';
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

const createBase64EnvConfigurationApi = <TSecretNames extends ReadonlyArray<string>>(
  secretNames: TSecretNames,
): ConfigurationApi<Record<TSecretNames[number], string>> => {
  return {
    get: async (name: TSecretNames[number]) => {
      const value = { ...env }[toEnvName(name)]
      if (!value) {
        throw new Error(`Configuration value ${name} not found.`)
      }

      return Buffer.from(value, "base64").toString("utf-8")
    },
    getNames: () => secretNames,
    set: async () => {
      throw new Error("Not implemented")
    },
  }
}

const provisionedSecretNames = [
  "nas/ip",
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
  "nas/openclaw/username",
  "nas/openclaw/password",
] as const
const provisionedEnvConfiguration = createEnvConfigurationApi(
  provisionedSecretNames,
)

const sealedEnvSecrets = [
  "grafana-admin/admin-password",
  "grafana-admin/admin",
  "home-assistant-token/token",
  "mqtt-credentials/password",
  "mqtt-credentials/username",
  "mqtt-passwd/passwd",
  "playnite-web-credentials/database-url",
  "playnite-web-credentials/secret",
  "playnite-web-db-credentials/username",
  "playnite-web-db-credentials/password",
  "psn-accounts/accounts",
  "regcred/email",
  "regcred/password",
  "regcred/server",
  "regcred/username",
  "tsauthkey",
  "tunnel-credentials/credentials.json",
  "unifi/ip",
  "unifi/password",
  "unifi/username",
  "homebox-oidc/client-secret",
  "homebox-oidc/client-id",
  "home-assistant/automation-editor-supervisor-token",
  "home-assistant/version-control-supervisor-token",
  "openclaw-db/username",
  "openclaw-db/password",
  "openclaw-redis-auth/username",
  "openclaw-redis-auth/password",
  "homebox-oidc/issuer-url",
] as const
const sealedBase64EnvSecrets = [
  "home-assistant/ssh-key-private",
] as const

const base64EnvConfiguration = createBase64EnvConfigurationApi(sealedBase64EnvSecrets)
const envConfiguration = createEnvConfigurationApi(sealedEnvSecrets)

const sealedSecretEnvConfiguration =
  createConfigurationApi([base64EnvConfiguration, envConfiguration])

export { provisionedEnvConfiguration, sealedSecretEnvConfiguration }
export default createEnvConfigurationApi
