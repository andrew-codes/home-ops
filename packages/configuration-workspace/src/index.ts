import { createConfigApi as createOnepasswordConfiguration } from "@ha/configuration-1password"
import { createConfigApi as createOnePasswordCliConfiguration } from "@ha/configuration-1password-cli"
import type { ConfigurationApi } from "@ha/configuration-api"
import { configurationApi as envConfiguration } from "@ha/configuration-env-secrets"
import { logger } from "@ha/logger"
import { uniq } from "lodash"
import type { Configuration } from "./Configuration.types"

const createConfigurationApi = async (
  providers: ConfigurationApi<any>[] = [envConfiguration],
): Promise<ConfigurationApi<Configuration>> => {
  const vaultId = await envConfiguration.get(`onepassword/vault-id`)
  if (!vaultId) {
    throw new Error(`No vault id found.`)
  }
  const onePasswordCliConfiguration =
    await createOnePasswordCliConfiguration(vaultId)
  const onePasswordConfiguration = await createOnepasswordConfiguration(
    vaultId,
    onePasswordCliConfiguration,
  )
  const configurationProviders = providers.concat(
    onePasswordConfiguration,
    onePasswordCliConfiguration,
  )

  return {
    get: async (name) => {
      for (const configurationProvider of configurationProviders) {
        try {
          const value = await configurationProvider.get(name)

          return value
        } catch (error) {}
      }
      throw new Error(`Configuration value not found, ${name}.`)
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
      const providers = configurationProviders.filter((provider) =>
        provider.getNames().includes(name),
      )
      for (const configurationProvider of providers) {
        try {
          await configurationProvider.set(name, value)
          return
        } catch (error) {
          logger.debug(
            `Configuration: Error setting value for ${name}: ${error?.message}. ConfigurationApi index: ${providers.indexOf(configurationProvider)}`,
          )
        }
      }

      throw new Error(
        `No configuration provider found to set value for ${name}.`,
      )
    },
  }
}

export { createConfigurationApi }
export type { Configuration, ResourceEnvironment }
