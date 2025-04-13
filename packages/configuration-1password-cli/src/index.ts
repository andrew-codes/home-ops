import { ConfigurationApi } from "@ha/configuration-api"
import { op as createOp } from "./op"

const configurationNames = [
  // Required Secrets
  "dev/ssh-key/public",
  "k8s/ip",
  "k8s/pod-network-cidr",
  "proxmox/host/pve",
  "proxmox/ip",
  "proxmox/nameserver",
  "proxmox/password",
  "proxmox/ssh-key/public",
  "proxmox/username",
  "unifi/ip",
  // set by provisioning
  "k8s/config",
  // legacy secrets
  "backup/config",
  "backup/nas/ssh-key/private",
  "backup/ssh-key/private",
  "backup/ssh-key/public",
  "captive-portal/host",
  "captive-portal/port/external",
  "cloudflare/email",
  "cloudflare/token",
  "cloudflare/zone-id",
  "cloudflared/config",
  "cloudflared/credentials",
  "coder/db/username",
  "coder/db/password",
  "crowdsec/elastic/password",
  "crowdsec/bouncer/nginx/key",
  "crowdsec/api/port/external",
  "crowdsec/dashboard/port/external",
  "crowdsec/db/name",
  "crowdsec/db/password",
  "crowdsec/db/username",
  "crowdsec/elastic/username",
  "crowdsec/password",
  "crowdsec/username",

  "docker-registry/hostname",
  "docker-registry/ip",
  "docker-registry/machine/username",
  "docker-registry/name",
  "docker-registry/password",
  "docker-registry/username",
  "domain",
  "elk-stack/elastic-search/port/external",
  "elk-stack/fleet/hostname",
  "elk-stack/fleet/ip",
  "elk-stack/kibana/port/external",
  "elk-stack/logstash/password",
  "elk-stack/logstash/port/external",
  "game-library-db/password",
  "game-library-db/port",
  "game-library-db/username",
  "game-room-remote/port/external",
  "gaming-assets-web/port",
  "gaming-assets-web/host",
  "gaming-pc/ip",
  "gaming-pc/machine/username",
  "gaming-pc/machine/password",
  "gaming-pc/user",
  "github/token",
  "github/email",
  "github/cr/token",
  "grafana/influxdb/token",
  "grafana/password",
  "grafana/port/external",
  "grafana/username",
  "guest-db/port",
  "guest-db/password",
  "guest-db/username",
  "guest-pin-codes/calendar-id",
  "guest-pin-codes/client-id",
  "guest-pin-codes/client-secret",
  "guest-pin-codes/door-locks",
  "guest-pin-codes/google-private-key",
  "guest-pin-codes/guest-code-index-offset",
  "guest-pin-codes/guest-lock-code-exclusions",
  "guest-pin-codes/number-of-guest-codes",
  "guest-pin-codes/tenant-id",
  "home-assistant/appdaemon/password",
  "home-assistant/appdaemon/url",
  "home-assistant/domain",
  "home-assistant/elevation",
  "home-assistant/game-room/gaming-pc/ip",
  "home-assistant/game-room/gaming-pc/mac",
  "home-assistant/game-room/gaming-pc/machine-username",
  "home-assistant/game-room/nintendo-switch/ip",
  "home-assistant/game-room/nvidia-shield/ip",
  "home-assistant/game-room/playstation-5/ip",
  "home-assistant/game-room/tv/ip",
  "home-assistant/game-room/tv/mac",
  "home-assistant/github/token",
  "home-assistant/google/calendar/client-id",
  "home-assistant/google/calendar/client-secret",
  "home-assistant/ssh-key/private",
  "home-assistant/ssh-key/public",
  "home-assistant/influxdb/token",
  "home-assistant/github-authorization-header",
  "home-assistant/latitude",
  "home-assistant/longitude",
  "home-assistant/o365-client-id",
  "home-assistant/o365-client-secret",
  "home-assistant/port/external",
  "home-assistant/server",
  "home-assistant/spotcast/dc-2",
  "home-assistant/spotcast/dc",
  "home-assistant/spotcast/key-2",
  "home-assistant/spotcast/key",
  "home-assistant/spotify/client-id",
  "home-assistant/spotify/client-secret",
  "home-assistant/time-zone",
  "home-assistant/token",
  "home-assistant/unit-system",
  "home-assistant/url",
  "home-assistant/withings/client-id",
  "home-assistant/withings/client-secret",
  "home-assistant/webrtc/api/port",
  "k8s/machine/password",
  "k8s/machine/username",
  "k8s/main-node/ip",
  "k8s/name",

  "known-hosts",
  "mqtt/password",
  "mqtt/port/external",
  "mqtt/username",
  "nfs/ip",
  "nfs/share-path",
  "onepassword/credentials",
  "onepassword/token/connect",
  "onepassword/server-url",
  "paperless/admin/mail",
  "paperless/admin/password",
  "paperless/admin/user",
  "paperless/port/external",
  "paperless/postgres-db",
  "paperless/postgres-password",
  "paperless/postgres-user",
  "paperless/secret-key",
  "paperless/url",
  "playnite-web/port/external",
  "playnite-web/secret",
  "playnite-web/username",
  "playnite-web/password",
  "playnite-web/staging/port/external",
  "photoprism/admin/password",
  "photoprism/admin/username",
  "photoprism/db/password",
  "photoprism/db/root/password",
  "photoprism/db/username",
  "photoprism/port/external",
  "pihole/domain",
  "pihole/hostname",
  "pihole/ip",
  "pihole/password",
  "pihole2/ip",

  "proxmox/provision/ssh-key/public",
  "proxmox/ssh-key/private",
  "ps5/credentials-json",
  "psn-accounts",
  "repository/name",
  "repository/other/names",
  "repository/owner",
  "tailscale/auth-key",
  "tailscale/hostname",
  "tailscale/ip",
  "tailscale/subnet-routes",
  "tunnel-proxy/auth",
  "tunnel-proxy/cert",
  "tunnel-proxy/tunnel-id",

  "unifi/password",
  "unifi/port",
  "unifi/username",
  "uptime-kuma/port/external",
  "wifi-porter/account-password",
  "wifi-porter/api-key",
  "wifi-porter/location-id",
  "zigbee2mqtt/port/external",
  "zwavejs/port/external",
  "zwavejs/port/external/web-socket",
] as const

type ConfigurationKeys = typeof configurationNames
type OnePasswordCliConfiguration = Record<
  ConfigurationKeys[number],
  { id: string; value: string }
>

const createConfigApi = async (
  vaultId: string,
): Promise<ConfigurationApi<OnePasswordCliConfiguration>> => {
  const op = await createOp(vaultId)

  return {
    get: async (name) => {
      const itemTitle = name
      const itemFieldName = "secret-value"
      const item = await op.getItemByTitle(itemTitle)
      const field = item?.fields?.find((f) => f.label === itemFieldName)

      if (!item?.id || !field?.value) {
        throw new Error(`Configuration value not found, ${name}.`)
      }

      return {
        id: item.id,
        value: field.value,
      }
    },
    getNames: () => configurationNames,
    set: async (name, value) => {
      const existingItem = await op.getItemByTitle(name)

      if (!!existingItem?.id) {
        await op.updateItemByTitle(name, value)
      } else {
        await op.createItem(name, value)
      }
    },
  }
}

export { configurationNames, createConfigApi }
export type { OnePasswordCliConfiguration as Configuration }
