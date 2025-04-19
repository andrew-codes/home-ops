import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { jsonnet } from "@ha/jsonnet"
import { kubectl } from "@ha/kubectl"
import path from "path"
import { name } from "./config"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const port_external = await configurationApi.get("uptime-kuma/port/external")
  const secrets: Array<keyof Configuration> = []
  const resources = await jsonnet.eval(
    path.join(__dirname, "..", "deployment", "index.jsonnet"),
    {
      image: `louislam/uptime-kuma:latest`,
      name,
      secrets,
      port: parseInt(port_external.value),
    },
  )
  const resourceJson = JSON.parse(resources)
  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const kube = kubectl()
  await Promise.all(
    resourceJson.map((resource) =>
      kube.applyToCluster(JSON.stringify(resource)),
    ),
  )

  await kube.rolloutDeployment("restart", name)
}

export default run
