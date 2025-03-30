import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import createFluxCd from "@ha/fluxcd"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
  context,
  options,
): Promise<void> => {
  if (!options.env) {
    throw new Error("No env provided.")
  }

  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const flux = createFluxCd(kubeConfig, configurationApi)
  const repository = (await configurationApi.get("repository/home-ops/name"))
    .value

  await flux.exec(`flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=${repository} \
  --branch=main \
  --path=clusters/${options.env} \
  --personal \
  --components-extra image-reflector-controller,image-automation-controller`)
}

export default run
