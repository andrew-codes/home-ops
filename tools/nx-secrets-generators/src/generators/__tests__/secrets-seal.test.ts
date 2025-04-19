import { sealedSecretEnvConfiguration } from "@ha/configuration-env-secrets"
import { Tree } from "@nx/devkit"
import { createTreeWithEmptyWorkspace } from "@nx/devkit/testing"
import { uniq } from "lodash"
import { SecretsGeneratorSchema } from "../schema"
import { secretsSealGenerator } from "../secrets-seal"

describe("secrets-seal generator", () => {
  let tree: Tree
  const options: SecretsGeneratorSchema = { env: "staging" }

  beforeEach(() => {
    tree = createTreeWithEmptyWorkspace()
    tree.write(
      `./._secrets.${options.env}.deploying.env`,
      "MQTT_CREDENTIALS_USERNAME=12345\nMQTT_CREDENTIALS_PASSWORD=67890\n",
    )
  })

  it("should create sealed k8s secret file for each k8s secret.", async () => {
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
  sealedSecretEnvConfiguration.getNames().map((name) => {
    return name.split("/").shift()
  }),
)
  .map((k8sSecretName) => {
    return `  - ${k8sSecretName}-sealed.yaml`
  })
  .join("\n")}`)

    sealedSecretEnvConfiguration.getNames().forEach((name) => {
      const k8sSecretName = name.split("/").shift()
      expect(
        tree.exists(
          `./infrastructure/${options.env}/secrets/${k8sSecretName}-sealed.yaml`,
        ),
      ).toBe(true)
    })
  })
})
