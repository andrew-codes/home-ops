import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { kubectl } from "@ha/kubectl"
import fs from "fs/promises"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
  context,
  { env },
): Promise<void> => {
  if (!env) {
    throw new Error("Environment variables not set")
  }

  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const kube = kubectl(kubeConfig)

  const publicKey = await kube.exec(`kubeseal --fetch-cert \
--controller-name=sealed-secrets-controller \
--controller-namespace=flux-system`)
  await fs.writeFile(path.join(__dirname, `../keys/${env}.pub`), publicKey, {
    encoding: "utf8",
    mode: 0o600,
  })
}

export default run
