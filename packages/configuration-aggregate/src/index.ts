import { ConfigurationApi } from "@ha/configuration-api"
import { logger } from "@ha/logger"
import { uniq } from "lodash"

// Only the failing provider's error text is surfaced, never a value.
const describeError = (error: unknown): string =>
  error instanceof Error ? error.message : String(error)

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
      const failures: Array<string> = []
      for (const configurationProvider of providers.filter((provider) =>
        provider.getNames().includes(name),
      )) {
        try {
          const value = await configurationProvider.get(name)

          return value
        } catch (error) {
          failures.push(
            `[provider ${providers.indexOf(configurationProvider)}] ${describeError(error)}`,
          )
        }
      }
      const reason = failures.length
        ? ` Provider errors:\n${failures.join("\n")}`
        : ""
      throw new Error(
        `Configuration value not found, ${String(name)}.${reason}`,
      )
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
