import { sealedOnePasswordConfiguration } from "@ha/configuration-1password"
import { spawn, type ChildProcess } from "node:child_process"
import { watch } from "node:fs"
import path from "node:path"

const run = async (): Promise<void> => {
  const haToken = await sealedOnePasswordConfiguration.get(
    "voice-agent/home-assistant-token",
  )
  const anthropicKey = await sealedOnePasswordConfiguration.get(
    "voice-agent/anthropic-api-key",
  )
  const langsmithKey = await sealedOnePasswordConfiguration.get(
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

  const appDir = path.join(__dirname, "..")
  const srcDir = path.join(appDir, "src")

  let child: ChildProcess | null = null
  let restarting = false

  const startProcess = () => {
    child = spawn("npx", ["@langchain/langgraph-cli", "dev"], {
      cwd: appDir,
      stdio: "inherit",
      env,
    })
    child.on("close", (code) => {
      if (!restarting) process.exit(code ?? 0)
    })
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
  watch(srcDir, { recursive: true }, (_event, filename) => {
    if (filename?.endsWith(".ts")) restart()
  })

  process.on("SIGINT", () => {
    child?.kill("SIGTERM")
    process.exit(0)
  })
  process.on("SIGTERM", () => {
    child?.kill("SIGTERM")
    process.exit(0)
  })

  startProcess()
}

export default run
