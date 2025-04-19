import { Tree } from "@nx/devkit"
import { createTreeWithEmptyWorkspace } from "@nx/devkit/testing"
import { SecretsGeneratorSchema } from "../schema"
import { secretsProvisioningGenerator } from "../secrets-provisioning"
jest.mock("@nx/devkit", () => {
  const original = jest.requireActual("@nx/devkit")
  return {
    ...original,
    formatFiles: jest.fn(), // no-op for tests
  }
})

describe("secrets-provisioning generator", () => {
  let tree: Tree
  const options: SecretsGeneratorSchema = { env: "test" }

  beforeEach(() => {
    tree = createTreeWithEmptyWorkspace()
  })

  it("should create a ._secrets.env var for the provided environment.", async () => {
    await secretsProvisioningGenerator(tree, options)
    expect(tree.exists("._secrets.test.provisioning.env")).toBe(true)
  })
})
