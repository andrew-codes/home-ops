import { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import { throwIfError } from "@ha/shell-utils"
import { mkdirSync, writeFileSync } from "fs"
import path from "path"
import sh from "shelljs"

const fluxcd = (
  kubeConfig: string,
  configApi: ConfigurationApi<Configuration>,
) => {
  let kubeConfigPath = path.join(__dirname, "..", "._secrets/.kube")
  mkdirSync(kubeConfigPath, { recursive: true })

  kubeConfigPath = path.join(kubeConfigPath, "config")
  writeFileSync(kubeConfigPath, kubeConfig.replace(/\\n/g, "\n"), {
    encoding: "utf8",
    mode: 0o600,
  })

  return {
    exec: async (
      command: string,
      env?: Record<string, string>,
    ): Promise<string> => {
      Object.entries(env ?? {}).forEach(([key, value]) => {
        if (value) {
          sh.env[key] = value
        }
      })
      sh.env["KUBECONFIG"] = kubeConfigPath
      sh.env["GITHUB_USER"] = (await configApi.get("github/username")).value
      sh.env["GITHUB_TOKEN"] = (await configApi.get("github/token")).value
      return throwIfError(
        sh.exec(`${command}`, {
          shell: "/bin/bash",
          silent: false,
        }),
      )
    },
    [Symbol.dispose]: () => {
      logger.debug(`Cleaning up fluxcd kubeconfig`)
      sh.rm(kubeConfigPath)
      sh.env["KUBECONFIG"] = ""
      sh.env["GITHUB_USER"] = ""
      sh.env["GITHUB_TOKEN"] = ""
    },
  }
}

export default fluxcd
