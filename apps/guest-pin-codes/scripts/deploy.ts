import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { jsonnet } from "@ha/jsonnet"
import { kubectl } from "@ha/kubectl"
import path from "path"
import { name } from "./config"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const registry = await configurationApi.get("docker-registry/hostname")
  const secrets: Array<keyof Configuration> = [
    "mqtt/password",
    "mqtt/username",
    "guest-pin-codes/client-id",
    "guest-pin-codes/client-secret",
    "guest-pin-codes/tenant-id",
    "guest-pin-codes/calendar-id",
    "guest-pin-codes/google-private-key",
    "guest-pin-codes/guest-lock-code-exclusions",
    "guest-pin-codes/number-of-guest-codes",
    "unifi/ip",
    "unifi/password",
    "unifi/port",
    "unifi/username",
  ]
  const resources = await jsonnet.eval(
    path.join(__dirname, "..", "deployment", "index.jsonnet"),
    {
      image: `${registry.value}/${name}:latest`,
      name,
      registryHostname: registry.value,
      secrets,
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
