import { spawnSync } from "child_process"
import path from "path"

/**
 * Applies the configuration to this machine.
 *
 * Runs the packaged setup.sh rather than src/setup.sh, so the monorepo path
 * exercises exactly the artifact a release ships. `deploy` depends on
 * `package`, so dist/andrew-mbp is already built by the time this runs.
 *
 * Uses spawnSync with inherited stdio rather than the shelljs helper other
 * deploys use: setup.sh is interactive. It prompts for sudo, and devtools'
 * setup can prompt about the configured username, so it needs a real TTY.
 */
const run = async (): Promise<void> => {
  const setupScript = path.join(
    __dirname,
    "..",
    "dist",
    "andrew-mbp",
    "setup.sh",
  )

  const result = spawnSync(setupScript, [], { stdio: "inherit" })

  if (result.error) {
    throw result.error
  }
  if (result.status !== 0) {
    throw new Error(`${setupScript} exited with code ${result.status}`)
  }
}

export default run
