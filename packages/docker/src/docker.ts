import type { ConfigurationApi } from "@ha/configuration-api"
import { type Configuration } from "@ha/configuration-workspace"
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
  const username = await configurationApi.get("github/username")
  const registryScope = "ghcr.io"
  const repo = "home-ops"
  const ci = process.env.CI === "true"

  return {
    build: async (name, options = {}) => {
      console.debug(
        `docker buildx build --build-arg OWNER=${username} --build-arg REPO=${repo} ${ci ? "--load" : ""} --platform linux/amd64${!ci ? ",linux/arm64" : ""} -t ${registryScope}/${username}/${name} ${
          options.context ?? process.cwd()
        } -f ${options.dockerFile ?? "Dockerfile"};`,
      )
      await throwIfError(
        sh.exec(
          `docker buildx build --build-arg OWNER=${username} --build-arg REPO=${repo} ${ci ? "--load" : ""} --platform linux/amd64${!ci ? ",linux/arm64" : ""} -t ${registryScope}/${username}/${name} ${
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
