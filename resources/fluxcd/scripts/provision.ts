import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import createFluxCd from "@ha/fluxcd"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
  context,
): Promise<void> => {
  const env = await configurationApi.get("env")
  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const flux = createFluxCd(kubeConfig, configurationApi)

  await flux.exec(`flux bootstrap github \
  --owner=andrew-codes \
  --repository=home-ops \
  --branch=main \
  --namespace=default \
  --path=clusters/${env} \
  --personal \
  --components-extra image-reflector-controller,image-automation-controller`)
}

export default run
