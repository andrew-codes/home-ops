import { throwIfError } from "@ha/shell-utils"
import type { ExecutorContext } from "@nx/devkit"
import sh from "shelljs"

interface TelepresenceExecutorOptions {
  image: string
  envOverrides?: string[]
  port: string
  volumes?: string[]
}

async function executor(
  options: TelepresenceExecutorOptions,
  context: ExecutorContext,
): Promise<{ success: boolean }> {
  try {
    const envShellOutput = sh.exec(`env`).stdout
    const envContentsToParse = `${envShellOutput}
${(options.envOverrides ?? []).join(`
`)}`
    const envVars = envContentsToParse.split("\n").reduce(
      (acc, line) => {
        if (line.replace(/\n/g, "") === "") {
          return acc
        }
        const split = line.split("=")
        if (split.length === 2 && split[0].match(/^[A-Z0-9_]+$/)) {
          acc.push({ name: split[0], value: split[1].trim() })
        } else if (split[0].match(/^[A-Z0-9_]+$/)) {
          const name = split[0]
          const value = split.splice(0, 1).join("")
          acc.push({ name, value })
        } else {
          acc[acc.length - 1].value = `${acc[acc.length - 1].value}
      ${line.trim()}`
        }

        return acc
      },
      [] as { name: string; value: string }[],
    )

    envVars.map(({ name, value }) => {
      sh.env[name] = value
    })
    const dockerEnvVars = envVars.map(({ name }) => `-e ${name}`).join(" ")
    const dockerVolumes = (options.volumes ?? [])
      .map((volumeMapping) => `-v "${volumeMapping}"`)
      .join(" ")
    const command = `docker run --name ${context.projectName} --rm -t ${dockerEnvVars} ${dockerVolumes} -p ${options.port} ${options.image}`
    await throwIfError(sh.exec(command))
  } catch (error) {
    console.log(error)
    return { success: false }
  }
  return { success: true }
}

export default executor
export type { TelepresenceExecutorOptions }
