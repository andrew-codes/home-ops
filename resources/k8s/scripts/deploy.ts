import { runPlaybook } from "@ha/ansible"
import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { kubectl } from "@ha/kubectl"
import { logger } from "@ha/logger"
import fs from "fs/promises"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
  context,
): Promise<void> => {
  const env = await configurationApi.get("env")
  const ip = (await configurationApi.get("k8s/ip")).value
  const networkCIDR = (await configurationApi.get("k8s/pod-network-cidr")).value
  const hostname = `${env}-k8s`

  const secretsPath = path.join(__dirname, "..", "._secrets", env)
  await fs.mkdir(secretsPath, { recursive: true })

  await runPlaybook(
    path.join(__dirname, "..", "src", "deployment", "deploy.yml"),
    [ip],
    {
      podNetwork: networkCIDR,
      podNetworkSubnet: `${networkCIDR.split("/")[0]}/24`,
      hostname,
      env,
    },
  )

  const kubeConfigPath = path.join(secretsPath, ".kube", "config")
  const kubeConfig = await fs.readFile(kubeConfigPath, "utf8")
  await configurationApi.set("k8s/config", kubeConfig.replace(/\n/g, "\\n"))
  const kube = kubectl()
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
