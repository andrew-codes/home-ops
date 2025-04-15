import { Configuration as OnePasswordConfiguration } from "@ha/configuration-1password-cli"
import { Configuration as EnvConfiguration } from "@ha/configuration-env-secrets"

type Configuration = {} & OnePasswordConfiguration & EnvConfiguration

export type { Configuration, EnvConfiguration, OnePasswordConfiguration }
