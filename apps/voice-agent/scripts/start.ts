import { sealedOnePasswordConfiguration } from "@ha/configuration-1password"
import { spawn } from "node:child_process"
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

  await new Promise<void>((resolve, reject) => {
    const child = spawn("npx", ["@langchain/langgraph-cli", "dev"], {
      cwd: path.join(__dirname, ".."),
      stdio: "inherit",
      env: {
        ...process.env,
        ANTHROPIC_API_KEY: anthropicKey,
        VOICE_AGENT_HA_BASE_URL:
          process.env.VOICE_AGENT_HA_BASE_URL ?? "https://ha.smith-simms.family",
        VOICE_AGENT_HA_TOKEN: haToken,
        VOICE_AGENT_AREA: process.env.VOICE_AGENT_AREA ?? "Kitchen",
        LANGCHAIN_TRACING_V2: "true",
        LANGCHAIN_API_KEY: langsmithKey,
        LANGCHAIN_PROJECT: "voice-agent",
      },
    })
    child.on("close", (code) => {
      if (code === 0 || code === null) resolve()
      else reject(new Error(`langgraph-cli exited with code ${code}`))
    })
    child.on("error", reject)
  })
}

export default run
