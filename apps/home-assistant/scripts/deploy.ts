import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { jsonnet } from "@ha/jsonnet"
import { kubectl } from "@ha/kubectl"
import path from "path"
import { name } from "./config"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const port = await configurationApi.get("home-assistant/port/external")
  const webrtcPort = await configurationApi.get(
    "home-assistant/webrtc/api/port",
  )
  const secrets: Array<keyof Configuration> = []
  const resources = await jsonnet.eval(
    path.join(__dirname, "..", "src", "deployment", "index.jsonnet"),
    {
      image: "homeassistant/home-assistant:2025.2.5",
      name,
      port: parseInt(port.value),
      "webrtc-port": parseInt(webrtcPort.value),
      secrets,
    },
  )
  const resourceJson = JSON.parse(resources)
  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const kube = kubectl(kubeConfig)
  await Promise.all(
    resourceJson.map((resource) =>
      kube.applyToCluster(JSON.stringify(resource)),
    ),
  )

  await kube.rolloutDeployment("restart", name)
}

export default run
