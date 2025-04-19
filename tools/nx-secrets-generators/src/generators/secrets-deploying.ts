import { sealedSecretEnvConfiguration } from "@ha/configuration-env-secrets"
import { toEnvName } from "@ha/secret-utils"
import { formatFiles, generateFiles, Tree } from "@nx/devkit"
import path from "path"
import { SecretsGeneratorSchema } from "./schema"

export async function secretsDeployingGenerator(
  tree: Tree,
  options: SecretsGeneratorSchema,
) {
  generateFiles(tree, path.join(__dirname, "files/provisioning"), ".", {
    ...options,
    prefix: "._",
    type: "deploying",
    names: sealedSecretEnvConfiguration
      .getNames()
      .map((name) => toEnvName(name)),
  })
  await formatFiles(tree)
}

export default secretsDeployingGenerator
