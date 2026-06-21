import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import build from "@ha/build-ts"
import { spawn, type ChildProcess } from "node:child_process"
import { watch } from "node:fs"
import path from "node:path"

const appDir = path.join(__dirname, "..")

const buildGraph = () =>
  build({
    entryPoints: [path.join(appDir, "src", "graph.ts")],
    outfile: path.join(appDir, "dist", "graph.js"),
    external: [],
  })

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const haToken = await configurationApi.get("voice-agent/home-assistant-token")
  const anthropicKey = await configurationApi.get(
    "voice-agent/anthropic-api-key",
  )
  const langsmithKey = await configurationApi.get(
    "voice-agent/langsmith-api-key",
  )

  const env = {
    ...process.env,
    ANTHROPIC_API_KEY: anthropicKey,
    VOICE_AGENT_HA_BASE_URL:
      process.env.VOICE_AGENT_HA_BASE_URL ?? "https://ha.smith-simms.family",
    VOICE_AGENT_HA_TOKEN: haToken,
    VOICE_AGENT_AREA: process.env.VOICE_AGENT_AREA ?? "Kitchen",
    LANGCHAIN_TRACING_V2: "true",
    LANGCHAIN_API_KEY: langsmithKey,
    LANGCHAIN_PROJECT: "voice-agent",
  }

  await new Promise<void>((resolve, reject) => {
    let child: ChildProcess | null = null
    let restarting = false

    const startProcess = () => {
      buildGraph()
        .then(() => {
          child = spawn("yarn", ["exec", "langgraphjs", "dev"], {
            cwd: appDir,
            stdio: "inherit",
            env,
          })
          child.on("error", reject)
          child.on("close", (code) => {
            if (!restarting) {
              code === 0 || code === null
                ? resolve()
                : reject(new Error(`langgraphjs exited with code ${code}`))
            }
          })
        })
        .catch(reject)
    }

    let debounce: ReturnType<typeof setTimeout> | null = null
    const restart = () => {
      if (debounce) clearTimeout(debounce)
      debounce = setTimeout(() => {
        if (restarting) return
        restarting = true
        console.log("\n[voice-agent] source changed — restarting…")
        child?.kill("SIGTERM")
        child?.once("close", () => {
          restarting = false
          startProcess()
        })
      }, 300)
    }

    // fs.watch recursive is stable on macOS/Linux since Node 20.
    watch(path.join(appDir, "src"), { recursive: true }, (_event, filename) => {
      if (filename?.endsWith(".ts")) restart()
    })

    process.on("SIGINT", () => {
      child?.kill("SIGTERM")
      resolve()
    })
    process.on("SIGTERM", () => {
      child?.kill("SIGTERM")
      resolve()
    })

    startProcess()
  })
}

export default run
