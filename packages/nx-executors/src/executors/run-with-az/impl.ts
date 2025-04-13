import { throwIfError } from "@ha/shell-utils"
import type { ExecutorContext } from "@nx/devkit"
import { exec } from "child_process"
import { promisify } from "util"

interface RunWithAzExecutorOptions {
  command: string
  cwd?: string
}

async function executor(
  { command, cwd }: RunWithAzExecutorOptions,
  context: ExecutorContext,
): Promise<{ success: boolean }> {
  try {
    const commandWithAz = `az login --service-principal --username $AZURE_SERVICE_PRINCIPAL_APP_ID --password $AZURE_SERVICE_PRINCIPAL_PASSWORD --tenant $AZURE_SERVICE_PRINCIPAL_TENANT
az account set --subscription $AZURE_SUBSCRIPTION_ID
${command}`
    const processPromise = promisify(exec)(commandWithAz, {
      cwd: cwd ?? process.cwd(),
    })
    let exitCode
    processPromise.child.on("close", (code) => {
      exitCode = code
    })
    const connectChildProcess = await processPromise
    await throwIfError({ ...connectChildProcess, code: exitCode })
  } catch (error) {
    console.log(error)
    return { success: false }
  }
  return { success: true }
}

export default executor
export type { RunWithAzExecutorOptions }
