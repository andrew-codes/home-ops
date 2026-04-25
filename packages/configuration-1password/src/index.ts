import { execFile as execFileCb } from "node:child_process"
import { promisify } from "node:util"
import { env } from "node:process"
import { ConfigurationApi } from "@ha/configuration-api"

const execFile = promisify(execFileCb)

const toOnePasswordReference = (secretName: string, vault: string): string => {
  const parts = secretName.split("/")
  if (parts.length === 1) {
    return `op://${vault}/${secretName}/credential`
  }
  const field = parts[parts.length - 1]
  const item = parts.slice(0, -1).join("-")
  return `op://${vault}/${item}/${field}`
}

const createOnePasswordConfigurationApi = <
  TSecretNames extends ReadonlyArray<string>,
>(
  secretNames: TSecretNames,
): ConfigurationApi<Record<TSecretNames[number], string>> => {
  return {
    get: async (name: TSecretNames[number]) => {
      const vault = env["OP_VAULT"]
      if (!vault) {
        throw new Error("OP_VAULT environment variable is not set.")
      }
      const reference = toOnePasswordReference(name as string, vault)
      const { stdout } = await execFile("op", ["read", "--no-newline", reference])
      return stdout
    },
    getNames: () => secretNames,
    set: async () => {
      throw new Error("Not implemented")
    },
  }
}

const secretNames = [
  "nas/ip",
  "dev/ssh-key/public",
  "env",
  "github/username",
  "github/token",
  "home-assistant/ssh-key-public",
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
  "gaming-pc/ip",
  "gaming-pc/user",
  "gaming-pc/username",
  "gaming-pc/password",
  "pbs/ip",
  "pbs/username",
  "pbs/password",
  "pbs/backup-username",
  "pbs/backup-password",
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
  "home-assistant/ssh-key-private",
] as const

const onePasswordConfiguration = createOnePasswordConfigurationApi(secretNames)

export { onePasswordConfiguration, toOnePasswordReference }
export default createOnePasswordConfigurationApi
