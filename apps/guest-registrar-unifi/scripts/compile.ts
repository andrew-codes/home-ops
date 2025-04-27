import build from "@ha/build-ts"
import type { ConfigurationApi } from "@ha/configuration-api"

import type { Configuration } from "@ha/configuration-workspace"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  await build()
}

export default run
