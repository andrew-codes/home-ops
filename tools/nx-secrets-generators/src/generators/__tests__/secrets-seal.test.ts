import { sealedOnePasswordConfiguration } from "@ha/configuration-1password"
import { Tree } from "@nx/devkit"
import { createTreeWithEmptyWorkspace } from "@nx/devkit/testing"
import { uniq } from "lodash"
import { SecretsGeneratorSchema } from "../schema"
import { secretsSealGenerator } from "../secrets-seal"

//  These tests can only be run locally as they require a kubectl context and 1Password CLI.
describe("secrets-seal generator", () => {
  let tree: Tree
  const options: SecretsGeneratorSchema = { env: "staging" }

  beforeEach(() => {
    tree = createTreeWithEmptyWorkspace()
  })

  test.skip("should create sealed k8s secret file for each k8s secret.", async () => {
    await secretsSealGenerator(tree, options)

    expect(
      tree.exists(`./infrastructure/${options.env}/secrets/kustomization.yaml`),
    ).toBe(true)
    expect(
      tree
        .read(`./infrastructure/${options.env}/secrets/kustomization.yaml`)
        ?.toString(),
    ).toEqual(`resources:
${uniq(
  sealedOnePasswordConfiguration.getNames().map((name) => {
    return name.split("/").shift()
  }),
)
  .map((k8sSecretName) => {
    return `  - ${k8sSecretName}-sealed.yaml`
  })
  .join("\n")}`)

    sealedOnePasswordConfiguration.getNames().forEach((name) => {
      const k8sSecretName = name.split("/").shift()
      expect(
        tree.exists(
          `./infrastructure/${options.env}/secrets/${k8sSecretName}-sealed.yaml`,
        ),
      ).toBe(true)
    })
  })
})
