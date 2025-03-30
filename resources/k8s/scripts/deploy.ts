import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { kubectl } from "@ha/kubectl"
import { logger } from "@ha/logger"
import fs from "fs/promises"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const ip = (await configurationApi.get("k8s/main-node/ip")).value
  const networkCIDR = (await configurationApi.get("k8s/pod-network-cidr")).value
  const hostname = (await configurationApi.get("k8s/name")).value

  const secretsPath = path.join(__dirname, "..", ".secrets")
  await fs.mkdir(secretsPath, { recursive: true })

  await runPlaybook(
    path.join(__dirname, "..", "src", "deployment", "deploy.yml"),
    [ip],
    {
      podNetwork: networkCIDR,
      podNetworkSubnet: `${networkCIDR.split("/")[0]}/24`,
      hostname,
    },
  )

  const kubeConfigPath = path.join(secretsPath, ".kube", "config")
  const kubeConfig = await fs.readFile(kubeConfigPath, "utf8")
  await configurationApi.set("k8s/config", kubeConfig.replace(/\n/g, "\\n"))
  const kube = kubectl(kubeConfig)
  try {
    await kube.exec(`kubectl create sa app;`)
  } catch (e) {
    logger.warn("app service account may already exist.")
    logger.error(e)
  }

  const configMap = JSON.parse(
    await kube.exec(
      `kubectl get cm kube-proxy -o json --namespace kube-system;`,
    ),
  )
  configMap.data["config.conf"] = configMap.data["config.conf"].replace(
    /maxPerCore: null/g,
    "maxPerCore: 0",
  )
  await kube.patch("kube-proxy", "cm", "kube-system", JSON.stringify(configMap))
}

export default run
