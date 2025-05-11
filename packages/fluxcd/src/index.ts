import workspaceConfigurationApi from "@ha/configuration-workspace"
import { throwIfError } from "@ha/shell-utils"
import path from "path"
import sh from "shelljs"

const fluxcd = (configApi: typeof workspaceConfigurationApi) => {
  return {
    exec: async (
      command: string,
      env?: Record<string, string>,
    ): Promise<string> => {
      const k8sEnv = await configApi.get("env")
      const kubeConfigPath = path.join(
        __dirname,
        `../../../resources/k8s/._secrets/${k8sEnv}/.kube/config`,
      )

      Object.entries(env ?? {}).forEach(([key, value]) => {
        if (value) {
          sh.env[key] = value
        }
      })
      return throwIfError(
        sh.exec(`${command}`, {
          shell: "/bin/bash",
          silent: false,
          env: {
            ...process.env,
            KUBECONFIG: kubeConfigPath,
            GITHUB_USER: await configApi.get("github/username"),
            GITHUB_TOKEN: await configApi.get("github/token"),
          },
        }),
      )
    },
  }
}

export default fluxcd
