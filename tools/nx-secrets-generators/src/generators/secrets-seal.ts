import { sealedSecretEnvConfiguration } from "@ha/configuration-env-secrets"
import { kubectl } from "@ha/kubectl"
import { toEnvName } from "@ha/secret-utils"
import { Tree } from "@nx/devkit"
import { isEmpty, merge } from "lodash"
import path from "node:path"
import { env } from "node:process"
import { SecretsGeneratorSchema } from "./schema"

export async function secretsSealGenerator(
  tree: Tree,
  options: SecretsGeneratorSchema,
) {
  env.ENV = options.env

  // Create the secrets directory if it doesn't exist
  const secretsDir = `./infrastructure/${options.env}/secrets`
  if (!tree.exists(secretsDir)) {
    tree.write(secretsDir, "")
  }

  // Create the secrets file
  const secretsFile = `._secrets.${options.env}.deploying.env`
  const secretsFromFile = Object.fromEntries(
    (tree.read(secretsFile)?.toString().split("\n") || [])
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .map((line) => line.split("=")),
  )

  const secrets = sealedSecretEnvConfiguration.getNames().reduce(
    (acc, name) => {
      const k8sSecretName = name.split("/").shift()
      const k8sKeyName = name.split("/").pop()
      if (!k8sSecretName || !k8sKeyName) {
        return acc
      }
      const value = secretsFromFile[toEnvName(name)]

      return merge({}, acc, {
        [k8sSecretName]: {
          [k8sKeyName]: value,
        },
      })
    },
    {} as Record<string, Record<string, string>>,
  )

  const kube = kubectl()
  for (const [k8sName, kv] of Object.entries(secrets)) {
    try {
      const values = Object.entries(kv)
        .map(([k, v]) => `--from-literal='${k}=${v}'`)
        .join(" ")

      if (isEmpty(values)) {
        console.debug(`No values found for ${k8sName}`)
        continue
      }

      const k8sSecret = await kube.exec(
        `kubectl create secret generic ${k8sName} ${values} --dry-run=client -o yaml `,
      )
      const sealedSecret = await kube.exec(
        `echo -n "${k8sSecret}" | kubeseal --format=yaml --cert=${path.join(__dirname, `../../../../resources/sealed-secrets/keys/${options.env}.pub`)}`,
      )

      tree.write(path.join(secretsDir, `${k8sName}-sealed.yaml`), sealedSecret)
    } catch (error) {
      console.error(`Error creating secret for ${k8sName}:`, error)
    }
  }

  tree.write(
    path.join(secretsDir, "kustomization.yaml"),
    `resources:
${Object.keys(secrets)
  .map((k8sSecretName) => {
    return `  - ${k8sSecretName}-sealed.yaml`
  })
  .join("\n")}`,
  )

  return () => {
    console.log(`Created ${secretsFile}`)
  }
}

export default secretsSealGenerator
