import { sealedSecretEnvConfiguration } from "@ha/configuration-env-secrets"
import { kubectl } from "@ha/kubectl"
import { Tree } from "@nx/devkit"
import { configDotenv } from "dotenv"
import { isEmpty, merge } from "lodash"
import path from "node:path"
import { env } from "node:process"
import { SecretsGeneratorSchema } from "./schema"

export async function secretsSealGenerator(
  tree: Tree,
  options: SecretsGeneratorSchema,
) {
  env.ENV = options.env

  const secretsFile = `._secrets.${options.env}.deploying.env`
  configDotenv({ path: secretsFile })

  let secrets: Record<string, Record<string, string>> = {}
  for (const name of sealedSecretEnvConfiguration.getNames()) {
    const k8sSecretName = name.split("/").shift()
    const k8sKeyName = name.split("/").pop()
    if (!k8sSecretName || !k8sKeyName) {
      continue
    }
    const value = await sealedSecretEnvConfiguration.get(name)

    secrets = merge({}, secrets, {
      [k8sSecretName]: {
        [k8sKeyName]: value,
      },
    })
  }

  const kube = kubectl()
  const secretsDir = `./infrastructure/${options.env}/secrets`
  for (const [k8sName, kv] of Object.entries(secrets)) {
    try {
      if (isEmpty(Object.keys(kv))) {
        console.debug(`No values found for ${k8sName}`)
        continue
      }

      let k8sSecret: string | null = null
      if (k8sName === "regcred") {
        k8sSecret = await kube.exec(
          `kubectl create secret docker-registry ${k8sName} --docker-server=${kv.server} --docker-username=${kv.username} --docker-email=${kv.email} --docker-password=${kv.password} --dry-run=client -o yaml`,
        )
      } else {
        const values = Object.entries(kv)
          .map(([k, v]) => `--from-literal='${k}=${v.replace(/\\n/g, "\n")}'`)
          .join(" ")

        if (isEmpty(values)) {
          console.debug(`No values found for ${k8sName}`)
          continue
        }
        k8sSecret = await kube.exec(
          `kubectl create secret generic ${k8sName} ${values} --dry-run=client -o yaml`,
        )
      }

      if (!k8sSecret) {
        console.debug(`No secret found for ${k8sName}`)
        continue
      }
      const sealedSecret = await kube.exec(
        `echo -n '${k8sSecret}' | kubeseal --format=yaml --cert=${path.join(__dirname, `../../../../resources/sealed-secrets/keys/${options.env}.pub`)}`,
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
