import { provisionedEnvConfiguration } from "@ha/configuration-env-secrets"
import { toEnvName } from "@ha/secret-utils"
import { formatFiles, generateFiles, Tree } from "@nx/devkit"
import * as path from "path"
import { SecretsGeneratorSchema } from "./schema"

export async function secretsProvisioningGenerator(
  tree: Tree,
  options: SecretsGeneratorSchema,
) {
  generateFiles(tree, path.join(__dirname, "files/provisioning"), ".", {
    ...options,
    prefix: "._",
    type: "provisioning",
    names: provisionedEnvConfiguration
      .getNames()
      .map((name) => toEnvName(name)),
  })
  await formatFiles(tree)
}

export default secretsProvisioningGenerator
