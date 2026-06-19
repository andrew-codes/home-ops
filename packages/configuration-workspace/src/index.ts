import { createConfigurationApi } from "@ha/configuration-aggregate"
import { onePasswordConfiguration } from "@ha/configuration-1password"
import type { ConfigurationApi } from "@ha/configuration-api"
import { env } from "node:process"

const envVarMap: Record<string, string> = {
  "github/username": "GITHUB_USERNAME",
  "github/token": "GITHUB_TOKEN",
}

const envConfiguration: ConfigurationApi<
  Record<keyof typeof envVarMap, string>
> = {
  get: async (name) => {
    const envVar = envVarMap[name as string]
    const value = envVar ? env[envVar] : undefined
    if (!value) {
      throw new Error(`Environment variable ${envVar} not set.`)
    }
    return value
  },
  getNames: () => Object.keys(envVarMap),
  set: async () => {
    throw new Error("Not implemented")
  },
}

const configurationApi = createConfigurationApi([
  onePasswordConfiguration,
  envConfiguration,
])

type ConfigurationKeys =
  (typeof configurationApi)["getNames"] extends () => infer T
    ? T extends ReadonlyArray<infer TSecretName>
      ? TSecretName extends infer TSecretNameString
        ? TSecretNameString extends string
          ? TSecretNameString
          : never
        : never
      : never
    : never
type Configuration = Record<ConfigurationKeys, string>

export default configurationApi
export type { Configuration }
