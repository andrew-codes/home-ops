import { execFile } from "node:child_process"
import { env } from "node:process"
import { Tree } from "@nx/devkit"
import { createTreeWithEmptyWorkspace } from "@nx/devkit/testing"

jest.mock("node:child_process", () => ({
  execFile: jest.fn(),
}))

jest.mock("@ha/configuration-1password", () => ({
  onePasswordConfiguration: {
    getNames: () => ["k8s/ip", "nas/openclaw/username", "tsauthkey"],
    get: jest.fn(),
    set: jest.fn(),
  },
  toOnePasswordReference: (secretName: string, vault: string) => {
    const parts = secretName.split("/")
    if (parts.length === 1) return `op://${vault}/${secretName}/credential`
    const field = parts[parts.length - 1]
    const item = parts.slice(0, -1).join("-")
    return `op://${vault}/${item}/${field}`
  },
}))

const mockedExecFile = execFile as unknown as jest.Mock

describe("secrets-1password generator", () => {
  let tree: Tree

  beforeEach(() => {
    tree = createTreeWithEmptyWorkspace()
    env["OP_VAULT"] = "test-vault"
    mockedExecFile.mockReset()
  })

  afterEach(() => {
    delete env["OP_VAULT"]
  })

  test("Throws when OP_VAULT is not set.", async () => {
    delete env["OP_VAULT"]
    const { secrets1passwordGenerator } = await import("../secrets-1password")
    await expect(secrets1passwordGenerator(tree, {})).rejects.toThrow(
      "OP_VAULT environment variable is not set.",
    )
  })

  test("Skips secrets that already have a value in 1Password.", async () => {
    mockedExecFile.mockImplementation((_file, args, callback) => {
      if (args[0] === "read") {
        callback(null, { stdout: "existing-value", stderr: "" })
      }
    })
    const { secrets1passwordGenerator } = await import("../secrets-1password")

    await secrets1passwordGenerator(tree, {})

    const createCalls = mockedExecFile.mock.calls.filter(
      ([, args]) => args[0] === "create",
    )
    expect(createCalls).toHaveLength(0)
  })

  test("Creates a new item and field when neither exists in 1Password.", async () => {
    mockedExecFile.mockImplementation((_file, args, callback) => {
      if (args[0] === "read") {
        callback(new Error("item not found"), null)
      } else if (args[0] === "item" && args[1] === "get") {
        callback(new Error("item not found"), null)
      } else if (args[0] === "item" && args[1] === "create") {
        callback(null, { stdout: "", stderr: "" })
      }
    })
    const { secrets1passwordGenerator } = await import("../secrets-1password")

    await secrets1passwordGenerator(tree, {})

    const createCalls = mockedExecFile.mock.calls.filter(
      ([, args]) => args[0] === "item" && args[1] === "create",
    )
    expect(createCalls).toHaveLength(3)
  })

  test("Adds a field to an existing item when the item exists but field does not.", async () => {
    mockedExecFile.mockImplementation((_file, args, callback) => {
      if (args[0] === "read") {
        callback(new Error("field not found"), null)
      } else if (args[0] === "item" && args[1] === "get") {
        callback(null, { stdout: "", stderr: "" })
      } else if (args[0] === "item" && args[1] === "edit") {
        callback(null, { stdout: "", stderr: "" })
      }
    })
    const { secrets1passwordGenerator } = await import("../secrets-1password")

    await secrets1passwordGenerator(tree, {})

    const editCalls = mockedExecFile.mock.calls.filter(
      ([, args]) => args[0] === "item" && args[1] === "edit",
    )
    expect(editCalls).toHaveLength(3)
    const createCalls = mockedExecFile.mock.calls.filter(
      ([, args]) => args[0] === "item" && args[1] === "create",
    )
    expect(createCalls).toHaveLength(0)
  })

  test("Creates item with correct title, vault, and field arguments.", async () => {
    mockedExecFile.mockImplementation((_file, args, callback) => {
      if (args[0] === "read") {
        callback(new Error("not found"), null)
      } else if (args[0] === "item" && args[1] === "get") {
        callback(new Error("not found"), null)
      } else {
        callback(null, { stdout: "", stderr: "" })
      }
    })
    const { secrets1passwordGenerator } = await import("../secrets-1password")

    await secrets1passwordGenerator(tree, {})

    expect(mockedExecFile).toHaveBeenCalledWith(
      "op",
      [
        "item",
        "create",
        "--category",
        "API Credential",
        "--title",
        "k8s",
        "--vault",
        "test-vault",
        "ip[text]=",
      ],
      expect.any(Function),
    )
  })

  test("Correctly maps a single-segment secret name to item and credential field.", async () => {
    mockedExecFile.mockImplementation((_file, args, callback) => {
      if (args[0] === "read") {
        callback(new Error("not found"), null)
      } else if (args[0] === "item" && args[1] === "get") {
        callback(new Error("not found"), null)
      } else {
        callback(null, { stdout: "", stderr: "" })
      }
    })
    const { secrets1passwordGenerator } = await import("../secrets-1password")

    await secrets1passwordGenerator(tree, {})

    expect(mockedExecFile).toHaveBeenCalledWith(
      "op",
      [
        "item",
        "create",
        "--category",
        "API Credential",
        "--title",
        "tsauthkey",
        "--vault",
        "test-vault",
        "credential[text]=",
      ],
      expect.any(Function),
    )
  })
})
