import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import fs from "fs/promises"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const k8sConfig = await configurationApi.get("k8s/config")

  await fs.mkdir(path.join("/root", ".kube"), { recursive: true })
  await fs.writeFile(
    path.join("/root", ".kube", "config"),
    k8sConfig.value.replace(/\\n/g, "\n"),
  )
}

export default run
