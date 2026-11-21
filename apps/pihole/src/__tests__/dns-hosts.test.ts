import {
  buildDnsHosts,
  gatewayHostnames,
  isMissingKeyError,
  isTailnetAddress,
} from "../dns-hosts"

describe("buildDnsHosts", () => {
  test("Builds one exact-name record per gateway hostname.", () => {
    expect(buildDnsHosts("100.101.102.103")).toEqual([
      "100.101.102.103 ha.smith-simms.family",
      "100.101.102.103 grafana.smith-simms.family",
      "100.101.102.103 zwave.smith-simms.family",
      "100.101.102.103 ps.smith-simms.family",
      "100.101.102.103 nas.smith-simms.family",
      "100.101.102.103 synology.smith-simms.family",
      "100.101.102.103 homebox.smith-simms.family",
    ])
  })

  test("Never emits a wildcard or the remodel site.", () => {
    const records = buildDnsHosts("100.101.102.103").join("\n")
    expect(records).not.toContain("*")
    expect(records).not.toContain("remodel")
    expect(gatewayHostnames).toHaveLength(7)
  })

  test("Trims whitespace around the address.", () => {
    expect(buildDnsHosts("100.64.0.1\n")[0]).toEqual(
      "100.64.0.1 ha.smith-simms.family",
    )
  })

  test.each([
    "",
    "not-an-ip",
    "192.168.1.5",
    "100.128.0.1",
    "100.63.0.1",
    "100.100.100.300",
    "fd7a:115c:a1e0::1",
  ])("Refuses %p because it is not a Tailscale IPv4 address.", (value) => {
    expect(() => buildDnsHosts(value)).toThrow(/Tailscale IPv4/)
  })
})

describe("isTailnetAddress", () => {
  test("Accepts the edges of 100.64.0.0/10.", () => {
    expect(isTailnetAddress("100.64.0.0")).toBe(true)
    expect(isTailnetAddress("100.127.255.255")).toBe(true)
  })
})

describe("isMissingKeyError", () => {
  test("Recognises a missing 1Password item or field.", () => {
    expect(
      isMissingKeyError(
        new Error(
          `[ERROR] "home-gateway" isn't an item in the "agents" vault.`,
        ),
      ),
    ).toBe(true)
    expect(
      isMissingKeyError(
        new Error(`"ip" isn't a field in the "home-gateway" item`),
      ),
    ).toBe(true)
  })

  test("Does not treat other failures as a missing key.", () => {
    expect(
      isMissingKeyError(new Error("You are not signed in to 1Password")),
    ).toBe(false)
    expect(isMissingKeyError("isn't an item")).toBe(false)
  })
})
