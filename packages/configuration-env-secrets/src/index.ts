import { ConfigurationApi } from "@ha/configuration-api"
import { toEnvName } from "@ha/secret-utils"
import { config } from "dotenv"
import path from "path"

const configurationNames = [
  "env",
  "onepassword/server-url",
  "onepassword/token",
  "onepassword/vault-id",
  "code-cov/token",
] as const

type ConfigurationKeys = typeof configurationNames
type Configuration = Record<ConfigurationKeys[number], string>

const configurationApi: ConfigurationApi<Configuration> = {
  get: async (name) => {
    const { parsed } = config({
      path: path.join(__dirname, "..", "..", "..", ".secrets.env"),
    })
    const value = ({ ...parsed, ...process.env } as unknown as Configuration)[
      toEnvName(name)
    ]
    if (!value) {
      throw new Error(`Configuration value ${name} not found.`)
    }

    return value
  },
  getNames: () => configurationNames as ReadonlyArray<keyof Configuration>,
  set: async () => {
    throw new Error("Not implemented")
  },
}

export { configurationApi }
export type { Configuration }
