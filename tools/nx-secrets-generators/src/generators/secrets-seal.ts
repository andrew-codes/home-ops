import { sealedOnePasswordConfiguration } from "@ha/configuration-1password"
import { kubectl } from "@ha/kubectl"
import { Tree } from "@nx/devkit"
import { isEmpty, merge } from "lodash"
import path from "node:path"
import { env } from "node:process"
import { SecretsGeneratorSchema } from "./schema"

// A namespace is always passed explicitly because `kubectl create secret
// --dry-run=client` only fills one in from the current kubeconfig context, and
// kubeseal (strict scope) refuses a secret without one. Without it the
// generator fails on a machine with no context.
const DEFAULT_NAMESPACE = "default"
const DEFAULT_DIRECTORY = "secrets"

// Where a sealed secret is written and which namespace it is sealed for, under
// ./infrastructure/<env>. A SealedSecret in a namespace that does not exist yet
// fails its whole Flux Kustomization, so a secret for a namespace that another
// Kustomization creates is written next to that Kustomization instead of into
// the shared secrets directory. The generator appends it to that directory's
// existing kustomization.yaml.
const SECRET_TARGETS: Record<string, { namespace: string; directory: string }> =
  {
    "tailscale-operator-oauth": {
      namespace: "tailscale",
      directory: "tailscale-operator",
    },
    "cloudflare-dns": {
      namespace: "cert-manager",
      directory: "cert-manager-issuers",
    },
  }

const targetOf = (k8sName: string) => {
  const target: { namespace: string; directory: string } | undefined =
    SECRET_TARGETS[k8sName]
  return (
    target ?? { namespace: DEFAULT_NAMESPACE, directory: DEFAULT_DIRECTORY }
  )
}

// Adds a resource to the resources list of an existing kustomization.yaml, and
// leaves the file as is when the resource is already listed.
const addKustomizationResource = (
  tree: Tree,
  kustomizationPath: string,
  resource: string,
) => {
  const current = tree.read(kustomizationPath)?.toString()
  if (current === undefined) {
    throw new Error(
      `${kustomizationPath} does not exist, so ${resource} cannot be added to it.`,
    )
  }
  const entry = `  - ${resource}`
  if (current.split("\n").some((line) => line.trim() === entry.trim())) {
    return
  }
  const resourcesBlock = /^resources:[ \t]*\n(?:[ \t]+- .*(?:\n|$))*/m
  const match = resourcesBlock.exec(current)
  if (!match) {
    throw new Error(`${kustomizationPath} has no resources list.`)
  }
  const block = match[0].endsWith("\n") ? match[0] : `${match[0]}\n`
  tree.write(kustomizationPath, current.replace(match[0], `${block}${entry}\n`))
}

export async function secretsSealGenerator(
  tree: Tree,
  options: SecretsGeneratorSchema,
) {
  env.ENV = options.env

  let secrets: Record<string, Record<string, string>> = {}
  for (const name of sealedOnePasswordConfiguration.getNames()) {
    const k8sSecretName = name.split("/").shift()
    const k8sKeyName = name.split("/").pop()
    if (!k8sSecretName || !k8sKeyName) {
      continue
    }
    const value = await sealedOnePasswordConfiguration.get(name)

    secrets = merge({}, secrets, {
      [k8sSecretName]: {
        [k8sKeyName]: value,
      },
    })
  }

  const kube = kubectl(options.env)
  const infrastructureDir = `./infrastructure/${options.env}`
  const secretsDir = path.join(infrastructureDir, DEFAULT_DIRECTORY)
  for (const [k8sName, kv] of Object.entries(secrets)) {
    const { namespace, directory } = targetOf(k8sName)
    try {
      if (isEmpty(Object.keys(kv))) {
        console.debug(`No values found for ${k8sName}`)
        continue
      }

      let k8sSecret: string | null = null
      if (k8sName === "regcred") {
        k8sSecret = await kube.exec(
          `kubectl create secret docker-registry ${k8sName} --docker-server=${kv.server} --docker-username=${kv.username} --docker-email=${kv.email} --docker-password=${kv.password} --namespace ${namespace} --dry-run=client -o yaml`,
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
          `kubectl create secret generic ${k8sName} ${values} --namespace ${namespace} --dry-run=client -o yaml`,
        )
      }

      if (!k8sSecret) {
        console.debug(`No secret found for ${k8sName}`)
        continue
      }
      const sealedSecret = await kube.exec(
        `echo -n '${k8sSecret}' | kubeseal --format=yaml --cert=${path.join(__dirname, `../../../../resources/sealed-secrets/keys/${options.env}.pub`)}`,
      )

      tree.write(
        path.join(infrastructureDir, directory, `${k8sName}-sealed.yaml`),
        sealedSecret,
      )
      if (directory !== DEFAULT_DIRECTORY) {
        addKustomizationResource(
          tree,
          path.join(infrastructureDir, directory, "kustomization.yaml"),
          `${k8sName}-sealed.yaml`,
        )
      }
    } catch (error) {
      console.error(`Error creating secret for ${k8sName}:`, error)
    }
  }

  tree.write(
    path.join(secretsDir, "kustomization.yaml"),
    `resources:
${Object.keys(secrets)
  .filter(
    (k8sSecretName) => targetOf(k8sSecretName).directory === DEFAULT_DIRECTORY,
  )
  .map((k8sSecretName) => {
    return `  - ${k8sSecretName}-sealed.yaml`
  })
  .join("\n")}`,
  )
}

export default secretsSealGenerator
