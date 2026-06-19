import build from "@ha/build-ts"
import path from "path"

/**
 * Bundle the service into a single self-contained file. We intentionally do NOT
 * mark dependencies as external (unlike most packages here): the workspace uses
 * Yarn PnP, so there is no node_modules to ship. Bundling everything into
 * dist/server.js lets the runtime image be a plain node:slim with no installs.
 */
const run = async (): Promise<void> => {
  await build({
    entryPoints: [path.join(__dirname, "..", "src", "server.ts")],
    outfile: path.join(__dirname, "..", "dist", "server.js"),
    external: [],
  })
}

export default run
