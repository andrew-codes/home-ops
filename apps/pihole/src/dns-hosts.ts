// The friendly names that resolve to the home gateway on the tailnet.
// Each becomes one exact-name A record in Pi-hole's `dns.hosts`. Never a
// wildcard: `*.smith-simms.family` would also capture `remodel`, `home` and
// `docs.home`, which must keep resolving through Cloudflare.
const zone = "smith-simms.family"

const gatewayHostnames = [
  "ha",
  "grafana",
  "zwave",
  "ps",
  "nas",
  "synology",
  "homebox",
] as const

// Tailscale assigns device addresses from the CGNAT range 100.64.0.0/10.
const isTailnetAddress = (value: string): boolean => {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(value)
  if (!match) {
    return false
  }
  const octets = match.slice(1).map(Number)
  if (octets.some((octet) => octet > 255)) {
    return false
  }
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127
}

// Returns the `dns.hosts` entries ("IP HOSTNAME") for the gateway address.
// Throws on anything that is not a Tailscale IPv4 address so a typo in the
// 1Password item can never become a record on both resolvers.
const buildDnsHosts = (gatewayIp: string): Array<string> => {
  const address = gatewayIp.trim()
  if (!isTailnetAddress(address)) {
    throw new Error(
      "home-gateway/ip is not a Tailscale IPv4 address (100.64.0.0/10). Refusing to write DNS records.",
    )
  }
  return gatewayHostnames.map((name) => `${address} ${name}.${zone}`)
}

// `op read` fails with an error naming the missing item or field when the
// 1Password key has not been created yet. Any other failure (not signed in,
// vault unreachable) is a real error and must not look like "key absent".
const isMissingKeyError = (error: unknown): boolean =>
  error instanceof Error &&
  /isn't an item|isn't a field|could not be found|no item found/i.test(
    error.message,
  )

// Pi-hole v6 `pihole-FTL --config dns.hosts` prints `[ ip host, ip host ]`
// with unquoted entries, which is not JSON (quoted entries are possible too).
// Extract every "<ipv4> <hostname>" pair. This pattern is also the
// `dns_host_pattern` var in src/dns-records*/index.yml; keep them in sync.
const dnsHostPattern = String.raw`\d{1,3}(?:\.\d{1,3}){3}\s+[\w.-]+`

const parseDnsHosts = (output: string): Array<string> =>
  (output.match(new RegExp(dnsHostPattern, "g")) ?? []).map((entry) =>
    entry.replace(/\s+/g, " "),
  )

export {
  buildDnsHosts,
  parseDnsHosts,
  gatewayHostnames,
  isMissingKeyError,
  isTailnetAddress,
  zone,
}
