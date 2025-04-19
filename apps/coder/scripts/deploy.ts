import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { jsonnet } from "@ha/jsonnet"
import { kubectl } from "@ha/kubectl"
import path from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const coderDbUsername = (await configurationApi.get("coder/db/username"))
    .value
  const coderDbPassword = (await configurationApi.get("coder/db/password"))
    .value
  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const kube = kubectl()

  await kube.exec(
    `kubectl create secret generic coder-db-url --from-literal=url="postgres://${coderDbUsername}:${coderDbPassword}@coder-postgres:5432/coder?sslmode=disable"`,
  )
  await kube.exec(`helm repo add coder-v2 https://helm.coder.com/v2`)
  await kube.exec(
    `helm install coder coder-v2/coder --values ${path.join(
      __dirname,
      "values.yaml",
    )} --version 2.16.1`,
  )
  await kube.exec(
    `helm upgrade coder coder-v2/coder -f ${path.join(
      __dirname,
      "values.yaml",
    )}`,
  )

  const resources = await jsonnet.eval(
    path.join(__dirname, "..", "deployment", "index.jsonnet"),
  )
  const resourceJson = JSON.parse(resources)
  await Promise.all(
    resourceJson.map((resource) =>
      kube.applyToCluster(JSON.stringify(resource)),
    ),
  )
}

export default run
