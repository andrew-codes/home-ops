import { runPlaybook } from "@ha/ansible"
import dnsRecords from "../../scripts/dns-records"

jest.mock("@ha/ansible", () => ({ runPlaybook: jest.fn() }))
jest.mock("@ha/logger", () => ({ logger: { info: jest.fn() } }))

const mockedRunPlaybook = runPlaybook as jest.Mock

const configurationWith = (values: Record<string, string | Error>) =>
  ({
    get: async (name: string) => {
      const value = values[name]
      if (value instanceof Error) {
        throw value
      }
      return value
    },
  }) as never

describe("dns-records", () => {
  test("Does nothing when the home-gateway/ip key is absent.", async () => {
    await dnsRecords(
      configurationWith({
        "home-gateway/ip": new Error(
          `[ERROR] "home-gateway" isn't an item in the "agents" vault.`,
        ),
      }),
    )
    expect(mockedRunPlaybook).not.toHaveBeenCalled()
  })

  test("Does nothing when the key is empty.", async () => {
    await dnsRecords(configurationWith({ "home-gateway/ip": "  \n" }))
    expect(mockedRunPlaybook).not.toHaveBeenCalled()
  })

  test("Rethrows other failures instead of treating the key as absent.", async () => {
    await expect(
      dnsRecords(
        configurationWith({
          "home-gateway/ip": new Error("You are not signed in to 1Password"),
        }),
      ),
    ).rejects.toThrow("not signed in")
    expect(mockedRunPlaybook).not.toHaveBeenCalled()
  })

  test("Refuses an address that is not on the tailnet.", async () => {
    await expect(
      dnsRecords(configurationWith({ "home-gateway/ip": "192.168.1.5" })),
    ).rejects.toThrow(/Tailscale IPv4/)
    expect(mockedRunPlaybook).not.toHaveBeenCalled()
  })

  test("Runs the records playbook against both Pi-holes with the records.", async () => {
    await dnsRecords(
      configurationWith({
        "home-gateway/ip": "100.101.102.103\n",
        "pihole/ip": "10.0.0.2",
        "pihole2/ip": "10.0.0.3",
      }),
    )
    expect(mockedRunPlaybook).toHaveBeenCalledTimes(1)
    const [playbook, hosts, vars] = mockedRunPlaybook.mock.calls[0]
    expect(playbook).toMatch(/src\/dns-records\/index\.yml$/)
    expect(hosts).toEqual(["10.0.0.2", "10.0.0.3"])
    expect(vars.dnsHosts).toContain("100.101.102.103 ha.smith-simms.family")
    expect(vars.dnsHosts).toHaveLength(7)
  })
})
