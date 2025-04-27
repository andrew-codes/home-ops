import { isProd } from "@ha/env-utils"
import esbuild, { BuildOptions } from "esbuild"
import { merge } from "lodash"
import path from "path"

const defaultConfig = {
  bundle: true,
  entryPoints: [path.join(process.cwd(), "src", "index.ts")],
  minify: isProd(),
  outfile: path.join(process.cwd(), "dist", "index.js"),
  platform: "node",
  sourcemap: true,
  target: "node22",
  resolveExtensions: [".ts", ".tsx", ".js"],
  define: { "process.env.NODE_ENV": `"${process.env.NODE_ENV}"` },
}

const build = async (overrides: BuildOptions = { external: [] }) => {
  overrides.external =
    overrides?.external?.filter((moduleName) => !/^@ha\/.*/.test(moduleName)) ??
    []
  await esbuild.build(merge({}, defaultConfig, overrides) as any)
}

export default build
