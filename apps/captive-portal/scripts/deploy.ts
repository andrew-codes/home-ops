import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { jsonnet } from "@ha/jsonnet"
import { kubectl } from "@ha/kubectl"
import fs from "fs/promises"
import path from "path"
import { name } from "./config"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const registry = await configurationApi.get("docker-registry/hostname")
  const port = await configurationApi.get("captive-portal/port/external")
  const unifiIp = await configurationApi.get("unifi/ip")
  const host = await configurationApi.get("captive-portal/host")
  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const kube = kubectl()

  const unifiCaptivePortal = `<!DOCTYPE html>
  <html>
    <head>
      <title>Smith-Simms Wifi</title>
      <meta http-equiv="refresh" content="0;url=https://${host.value}/register/<unifi var="mac" />">
    </head>
    <body>
    </body>
  </html>`
  await fs.mkdir(path.join(__dirname, "..", ".secrets"), { recursive: true })
  await fs.writeFile(
    path.join(__dirname, "..", ".secrets", "unifi.html"),
    unifiCaptivePortal,
    "utf8",
  )
  // await throwIfError(
  //   sh.exec(
  //     `scp -O ${path.join(__dirname, "..", ".secrets", "unifi.html")} "root@${
  //       unifiIp.value
  //     }:/data/unifi/data/sites/default/app-unifi-hotspot-portal/index.html"`,
  //   ),
  // )

  const secrets: Array<keyof Configuration> = [
    "mqtt/password",
    "mqtt/username",
    "unifi/ip",
    "unifi/port",
    "unifi/password",
    "unifi/username",
  ]
  const resources = await jsonnet.eval(
    path.join(__dirname, "..", "deployment", "index.jsonnet"),
    {
      image: `${registry.value}/${name}:latest`,
      name,
      secrets,
      port: parseInt(port.value),
    },
  )
  const resourceJson = JSON.parse(resources)
  await Promise.all(
    resourceJson.map((resource) =>
      kube.applyToCluster(JSON.stringify(resource)),
    ),
  )

  await kube.rolloutDeployment("restart", name)
}

export default run
