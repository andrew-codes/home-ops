import { provisionedEnvConfiguration } from "@ha/configuration-env-secrets"
import { throwIfError } from "@ha/shell-utils"
import fs from "fs/promises"
import path from "path"
import sh from "shelljs"
import { v4 as uuidv4 } from "uuid"

type DeploymentOptions = {
  namespace: string
}
type DeploymentCommand = "restart"

const kubectl = () => {
  return {
    applyToCluster: async (content: string): Promise<void> => {
      const env = await provisionedEnvConfiguration.get("env")
      let kubeConfigPath = path.join(
        __dirname,
        `../../../resources/k8s/._secrets/${env}/.kube/config`,
      )
      const fileName = uuidv4()
      try {
        await fs.mkdir("/tmp")
      } catch (e) {}
      await fs.writeFile(path.join("/tmp", fileName), content)
      await throwIfError(
        sh.exec(`kubectl apply --namespace default -f /tmp/${fileName};`, {
          shell: "/bin/bash",
          silent: false,
          env: {
            ...process.env,
            KUBECONFIG: kubeConfigPath,
          },
        }),
      )
      await fs.unlink(path.join("/tmp", fileName))
    },
    patch: async (
      name: string,
      resourceType: string,
      namespace: string,
      content: string,
    ): Promise<void> => {
      const env = await provisionedEnvConfiguration.get("env")
      let kubeConfigPath = path.join(
        __dirname,
        `../../../resources/k8s/._secrets/${env}/.kube/config`,
      )
      await throwIfError(
        sh.exec(
          `kubectl patch ${resourceType} --namespace ${namespace} ${name} --patch="$(echo -n '${content}' | sed 's/"/\\"/g')";`,
          {
            shell: "/bin/bash",
            silent: true,
            env: {
              ...process.env,
              KUBECONFIG: kubeConfigPath,
            },
          },
        ),
      )
    },
    rolloutDeployment: async (
      command: DeploymentCommand,
      deploymentName: string,
      options: DeploymentOptions = { namespace: "default" },
    ): Promise<void> => {
      const env = await provisionedEnvConfiguration.get("env")
      let kubeConfigPath = path.join(
        __dirname,
        `../../../resources/k8s/._secrets/${env}/.kube/config`,
      )
      await throwIfError(
        sh.exec(
          `kubectl -n ${options.namespace} rollout ${command} deployment ${deploymentName};`,
          {
            shell: "/bin/bash",
            silent: true,
            env: {
              ...process.env,
              KUBECONFIG: kubeConfigPath,
            },
          },
        ),
      )
    },
    exec: async (command: string): Promise<string> => {
      const env = await provisionedEnvConfiguration.get("env")
      let kubeConfigPath = path.join(
        __dirname,
        `../../../resources/k8s/._secrets/${env}/.kube/config`,
      )
      return throwIfError(
        sh.exec(`${command}`, {
          shell: "/bin/bash",
          silent: true,
          env: {
            ...process.env,
            KUBECONFIG: kubeConfigPath,
          },
        }),
      )
    },
  }
}

export default kubectl
