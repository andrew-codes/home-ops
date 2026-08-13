import { spawnSync } from "child_process"
import path from "path"

/**
 * Applies the configuration to this machine by running src/setup.sh.
 *
 * setup.sh reads only files that sit next to it, so running it straight out of
 * the working tree is the whole deployment - `git pull` then re-run is the
 * update path, with no build or packaging step in between.
 *
 * Uses spawnSync with inherited stdio rather than the shelljs helper other
 * deploys use: setup.sh is interactive. It prompts for sudo, so it needs a
 * real TTY. It also inherits this process's environment, which is how the
 * required ADMIN_* and NAS_* variables reach it.
 *
 * Deliberately a near-copy of the sibling apps/andrew-mbp's deploy script
 * rather than a shared module. It is fifteen lines with no configuration, and
 * the only way to share it would be a new workspace package that the
 * `@ha/nx-executors:invoke` executor then has to resolve through - more
 * indirection than the duplication costs.
 */
const run = async (): Promise<void> => {
  const setupScript = path.join(__dirname, "..", "src", "setup.sh")

  const result = spawnSync(setupScript, [], { stdio: "inherit" })

  if (result.error) {
    throw result.error
  }
  if (result.status !== 0) {
    throw new Error(`${setupScript} exited with code ${result.status}`)
  }
}

export default run
