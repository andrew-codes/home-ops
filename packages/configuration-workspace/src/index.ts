import { createConfigApi as createOnePasswordCliConfiguration } from "@ha/configuration-1password-cli"
import type { ConfigurationApi } from "@ha/configuration-api"
import { configurationApi as envConfiguration } from "@ha/configuration-env-secrets"
import { logger } from "@ha/logger"
import { uniq } from "lodash"
import type { Configuration } from "./Configuration.types"

const createConfigurationApi = async (
  providers: ConfigurationApi<any>[] = [envConfiguration],
): Promise<ConfigurationApi<Configuration>> => {
  const configurationProviders = providers

  try {
    const vaultId = await envConfiguration.get(`onepassword/vault-id`)
    if (vaultId) {
      configurationProviders.push(
        await createOnePasswordCliConfiguration(vaultId),
      )
    }
  } catch (error) {}

  return {
    get: async (name) => {
      for (const configurationProvider of configurationProviders) {
        try {
          const value = await configurationProvider.get(name)

          return value
        } catch (error) {}
      }
      throw new Error(`Configuration value not found, ${String(name)}.`)
    },
    getNames: () => {
      const allConfiguration = configurationProviders.reduce<
        ReadonlyArray<string>
      >(
        (acc, provider) =>
          acc.concat(provider.getNames() as ReadonlyArray<string>),
        [],
      )

      return uniq(allConfiguration) as (keyof Configuration)[]
    },
    set: async (name, value) => {
      const providers = configurationProviders.filter((provider) => {
        return provider.getNames().includes(name)
      })

      for (const configurationProvider of providers) {
        try {
          await configurationProvider.set(name, value)
        } catch (error) {
          logger.debug(
            `Configuration: Error setting value for ${String(name)}. ConfigurationApi index: ${providers.indexOf(configurationProvider)}.
Error: ${String(error)}`,
          )
        }
      }
    },
  }
}

export { createConfigurationApi }
export type { Configuration }
