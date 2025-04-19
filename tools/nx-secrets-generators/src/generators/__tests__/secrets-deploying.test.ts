import { Tree } from "@nx/devkit"
import { createTreeWithEmptyWorkspace } from "@nx/devkit/testing"
import { SecretsGeneratorSchema } from "../schema"
import { secretsDeployingGenerator } from "../secrets-deploying"
jest.mock("@nx/devkit", () => {
  const original = jest.requireActual("@nx/devkit")
  return {
    ...original,
    formatFiles: jest.fn(), // no-op for tests
  }
})

describe("secrets-deploying generator", () => {
  let tree: Tree
  const options: SecretsGeneratorSchema = { env: "test" }

  beforeEach(() => {
    tree = createTreeWithEmptyWorkspace()
  })

  it("should create a ._secrets.env var for the provided environment.", async () => {
    await secretsDeployingGenerator(tree, options)
    expect(tree.exists("._secrets.test.deploying.env")).toBe(true)
  })
})
