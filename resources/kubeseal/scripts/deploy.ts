import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import createFluxCd from "@ha/fluxcd"
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
  const flux = createFluxCd(kubeConfig, configurationApi)

  await flux.exec(`flux create source helm sealed-secrets \
--interval=1h \
--url=https://bitnami-labs.github.io/sealed-secrets`)

  await flux.exec(`flux create helmrelease sealed-secrets \
--interval=1h \
--release-name=sealed-secrets-controller \
--target-namespace=flux-system \
--source=HelmRepository/sealed-secrets \
--chart=sealed-secrets \
--chart-version=">=1.15.0-0" \
--crds=CreateReplace`)

  const publicKey = await flux.exec(`kubeseal --fetch-cert \
--controller-name=sealed-secrets-controller \
--controller-namespace=flux-system`)
  await fs.writeFile(path.join(__dirname, `../keys/${env}.pub`), publicKey, {
    encoding: "utf8",
    mode: 0o600,
  })

  await configurationApi.set("kubeseal/key/public", publicKey)
}

export default run
