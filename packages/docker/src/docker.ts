import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { throwIfError } from "@ha/shell-utils"
import process from "process"
import sh from "shelljs"

type DockerBuildOptions = {
  context?: string
  dockerFile?: string
}

interface DockerClient {
  build(name: string, options?: DockerBuildOptions): Promise<void>
  pushImage(name: string): Promise<void>
}

const createClient = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<DockerClient> => {
  const registry = "https://ghcr.io"
  const username = (await configurationApi.get("docker-registry/username"))
    .value
  const password = (await configurationApi.get("docker-registry/password"))
    .value
  const registryScope = "ghcr.io"
  const repo = "home-ops"

  return {
    build: async (name, options = {}) => {
      await throwIfError(
        sh.exec(
          `docker buildx build --build-arg OWNER=${username} --build-arg REPO=${repo} --load --platform linux/amd64 -t ${registryScope}/${username}/${name} ${
            options.context ?? process.cwd()
          } -f ${options.dockerFile ?? "Dockerfile"};`,
          { async: true, silent: false },
        ),
      )
    },
    pushImage: async (name) => {
      await throwIfError(
        sh.exec(`docker push ${registryScope}/${username}/${name};`, {
          async: true,
          silent: true,
        }),
      )
    },
  }
}

export { createClient }
export type { DockerClient }
