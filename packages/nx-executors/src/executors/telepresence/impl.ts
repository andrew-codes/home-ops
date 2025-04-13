import { createConfigurationApi } from "@ha/configuration-workspace"
import { throwIfError } from "@ha/shell-utils"
import type { ExecutorContext } from "@nx/devkit"
import { spawn } from "child_process"
import fs from "fs"
import path from "path"
import sh from "shelljs"

interface TelepresenceExecutorOptions {
  image: string
  port: number
  serviceName?: string
  envOverrides?: string[]
  volumes?: string[]
  pull?: boolean
}

async function executor(
  options: TelepresenceExecutorOptions,
  context: ExecutorContext,
): Promise<{ success: boolean }> {
  let exitCommand
  try {
    if (!context.projectName || !options.port || !options.image) {
      return { success: false }
    }

    process.on("exit", () => {
      console.log(`

-----------------------------------------------------------------------
Stop the docker container "${context.projectName}" to exit development:`)
      console.log(`Run \`docker kill ${context.projectName}\` in the terminal.`)
    })

    sh.exec(`umount /tmp/${context.projectName}`)
    sh.exec(`mkdir -p /tmp/${context.projectName}`)

    const configApi = await createConfigurationApi()
    const k8sUsername = await configApi.get("k8s/machine/username")
    const k8sPassword = await configApi.get("k8s/machine/password")
    const k8sIp = await configApi.get("k8s/main-node/ip")
    exitCommand = `
telepresence uninstall --agent ${context.projectName};
umount /tmp/${context.projectName};
ssh -t ${k8sUsername}@${k8sIp} "umount /home/${k8sUsername}/mnt/data/${context.projectName}";
`
    console.log("Preparing remote file system for mount.")
    sh.exec(
      `echo '${k8sPassword}' | ssh -tt ${k8sUsername}@${k8sIp} "mkdir -p ~/mnt/data/${context.projectName}; sudo bindfs --map=root/${k8sUsername} /mnt/data/${context.projectName} ~/mnt/data/${context.projectName}"`,
    )
    console.log(
      `Mounting ${k8sIp}:/home/${k8sUsername}/mnt/data/${context.projectName} to /tmp/${context.projectName}.`,
    )
    await throwIfError(
      sh.exec(
        `sshfs ${k8sUsername}@${k8sIp}:/home/${k8sUsername}/mnt/data/${context.projectName} /tmp/${context.projectName}`,
      ),
    )

    if (options.pull) {
      await throwIfError(sh.exec(`docker pull ${options.image}`))
    }

    const command = `telepresence intercept "${
      context.projectName
    }" --service "${options.serviceName ?? context.projectName}" --port ${
      options.port
    }:${
      options.port
    } --mount false --docker-run -- --rm --dns 127.0.0.1 --dns 10.1.0.130 --name ${
      context.projectName
    } ${(options.envOverrides ?? [])
      .map((override) => `--env ${override}`)
      .join(" ")} --env TELEPRESENCE_ROOT=/tmp/${context.projectName} ${(
      options.volumes ?? []
    )
      .map(
        (v) =>
          `-v ${path.resolve(context.root, v.split(":")[0])}:${
            v.split(":")[1]
          }`,
      )
      .join(" ")} -v /tmp/${context.projectName}:/tmp/${context.projectName} ${
      options.image
    }`

    sh.exec("mkdir -p ./logs")
    const out = fs.openSync(`./logs/${context.projectName}.out.log`, "w")
    const err = fs.openSync(`./logs/${context.projectName}.err.log`, "w")

    console.log(`
${command}`)
    const child = spawn(`${command} || (${exitCommand})`, {
      detached: true,
      shell: "bash",
      stdio: ["ignore", out, err],
    })
    child.unref()
  } catch (error) {
    console.log(error)
    console.log("Performing exit command", exitCommand)
    sh.exec(exitCommand)
    return { success: false }
  }
  return { success: true }
}

export default executor
export type { TelepresenceExecutorOptions }
