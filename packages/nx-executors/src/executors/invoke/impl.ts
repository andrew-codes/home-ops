import workspaceConfigurationApi from "@ha/configuration-workspace"
import { logger } from "@ha/logger"
import type { ExecutorContext } from "@nx/devkit"
import { register } from "esbuild-register/dist/node"
import path from "path"
import process from "process"

interface InvokeExecutorOptions {
  module: string
  cwd?: string
}

async function executor(
  options: InvokeExecutorOptions & Record<string, string>,
  context: ExecutorContext,
): Promise<{ success: boolean }> {
  try {
    const { cwd, module } = options
    register()
    let currentDir = path.resolve(context.root)
    if (!!cwd) {
      currentDir = path.resolve(context.root, cwd)
    }
    process.chdir(currentDir)
    const loadedModule = require(path.resolve(currentDir, module))
    await loadedModule.default(workspaceConfigurationApi, context, options)
  } catch (error) {
    if (error instanceof Error) {
      logger.error((error as Error).message)
    } else {
      logger.error(JSON.stringify(error))
    }

    return { success: false }
  }
  return { success: true }
}

export default executor
export type { InvokeExecutorOptions }
