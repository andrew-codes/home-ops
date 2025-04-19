import { createConfigurationApi } from "@ha/configuration-aggregate"
import {
  provisionedEnvConfiguration,
  sealedSecretEnvConfiguration,
} from "@ha/configuration-env-secrets"

const configurationApi = createConfigurationApi([
  provisionedEnvConfiguration,
  sealedSecretEnvConfiguration,
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
