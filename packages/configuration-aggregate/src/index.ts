import { ConfigurationApi } from "@ha/configuration-api"
import { logger } from "@ha/logger"
import { uniq } from "lodash"

const createConfigurationApi = <
  TProviders extends ReadonlyArray<ConfigurationApi<Record<string, string>>>,
>(
  providers: TProviders,
): ConfigurationApi<
  Record<
    (
      TProviders[number]["getNames"] extends () => infer T ? T : never
    ) extends ReadonlyArray<infer TSecretName>
      ? TSecretName extends infer TSecretNameString
        ? TSecretNameString extends string
          ? TSecretNameString
          : never
        : never
      : never,
    string
  >
> => {
  return {
    get: async (name) => {
      for (const configurationProvider of providers.filter((provider) =>
        provider.getNames().includes(name),
      )) {
        try {
          const value = await configurationProvider.get(name)

          return value
        } catch (error) {}
      }
      throw new Error(`Configuration value not found, ${String(name)}.`)
    },
    getNames: () => {
      const allConfiguration = providers.reduce(
        (acc, provider) => acc.concat(provider.getNames()),
        [] as Array<string>,
      )

      return uniq(allConfiguration) as (
        TProviders[number]["getNames"] extends () => infer T ? T : never
      ) extends ReadonlyArray<infer TSecretName>
        ? TSecretName extends infer TSecretNameString
          ? TSecretNameString extends string
            ? TSecretNameString
            : never
          : never
        : never
    },
    set: async (name, value) => {
      for (const configurationProvider of providers.filter((provider) =>
        provider.getNames().includes(name),
      )) {
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
