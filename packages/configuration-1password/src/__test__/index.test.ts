import { execFile } from "node:child_process"
import { env } from "node:process"

jest.mock("node:child_process", () => ({
  execFile: jest.fn(),
}))

const mockedExecFile = execFile as unknown as jest.Mock

describe("toOnePasswordReference", () => {
  test("Maps a two-part secret name to item and field.", async () => {
    const { toOnePasswordReference } = await import("..")
    expect(toOnePasswordReference("k8s/ip", "my-vault")).toEqual(
      "op://my-vault/k8s/ip",
    )
  })

  test("Maps a three-part secret name by joining all but last with dashes as item.", async () => {
    const { toOnePasswordReference } = await import("..")
    expect(toOnePasswordReference("nas/openclaw/username", "my-vault")).toEqual(
      "op://my-vault/nas-openclaw/username",
    )
  })

  test("Maps a single-part secret name to item with credential field.", async () => {
    const { toOnePasswordReference } = await import("..")
    expect(toOnePasswordReference("tsauthkey", "my-vault")).toEqual(
      "op://my-vault/tsauthkey/credential",
    )
  })
})

describe("createOnePasswordConfigurationApi", () => {
  beforeEach(() => {
    env["OP_VAULT"] = "test-vault"
    mockedExecFile.mockReset()
  })

  afterEach(() => {
    delete env["OP_VAULT"]
  })

  test("Calls op read with the correct 1Password reference.", async () => {
    mockedExecFile.mockImplementation((_file, _args, callback) => {
      callback(null, { stdout: "192.168.1.1", stderr: "" })
    })
    const createOnePasswordConfigurationApi = (await import("..")).default
    const api = createOnePasswordConfigurationApi(["k8s/ip"] as const)

    await api.get("k8s/ip")

    expect(mockedExecFile).toHaveBeenCalledWith(
      "op",
      ["read", "--no-newline", "op://test-vault/k8s/ip"],
      expect.any(Function),
    )
  })

  test("Returns the value from op read.", async () => {
    mockedExecFile.mockImplementation((_file, _args, callback) => {
      callback(null, { stdout: "192.168.1.1", stderr: "" })
    })
    const createOnePasswordConfigurationApi = (await import("..")).default
    const api = createOnePasswordConfigurationApi(["k8s/ip"] as const)

    const result = await api.get("k8s/ip")

    expect(result).toEqual("192.168.1.1")
  })

  test("Throws when OP_VAULT environment variable is not set.", async () => {
    delete env["OP_VAULT"]
    const createOnePasswordConfigurationApi = (await import("..")).default
    const api = createOnePasswordConfigurationApi(["k8s/ip"] as const)

    await expect(api.get("k8s/ip")).rejects.toThrow(
      "OP_VAULT environment variable is not set.",
    )
  })

  test("Throws when op CLI returns an error.", async () => {
    mockedExecFile.mockImplementation((_file, _args, callback) => {
      callback(new Error("item not found"), "", "item not found")
    })
    const createOnePasswordConfigurationApi = (await import("..")).default
    const api = createOnePasswordConfigurationApi(["k8s/ip"] as const)

    await expect(api.get("k8s/ip")).rejects.toThrow("item not found")
  })

  test("getNames returns the provided secret names.", async () => {
    const createOnePasswordConfigurationApi = (await import("..")).default
    const api = createOnePasswordConfigurationApi([
      "k8s/ip",
      "github/token",
    ] as const)

    expect(api.getNames()).toEqual(["k8s/ip", "github/token"])
  })

  test("set throws not implemented.", async () => {
    const createOnePasswordConfigurationApi = (await import("..")).default
    const api = createOnePasswordConfigurationApi(["k8s/ip"] as const)

    await expect(api.set("k8s/ip", "value")).rejects.toThrow("Not implemented")
  })
})
