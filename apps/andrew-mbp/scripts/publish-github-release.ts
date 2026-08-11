import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { throwIfError } from "@ha/shell-utils"
import { execSync } from "child_process"
import path from "path"
import sh from "shelljs"

const owner = "andrew-codes"
const repo = "home-ops"
const artifactName = "andrew-mbp.zip"

/**
 * Publishes dist/andrew-mbp.zip as a GitHub Release asset.
 *
 * Tag and artifact naming follow apps/gaming-pc's release script, including
 * its idempotent "release already exists" check. GitHub is driven through
 * gh-axi rather than Octokit.
 */
const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const token = await configurationApi.get("github/token")
  sh.env["GH_TOKEN"] = token

  const gitSha = execSync("git rev-parse HEAD", { encoding: "utf-8" }).trim()
  const shortSha = gitSha.substring(0, 7)
  const now = new Date()
  // YYYYMMDD-HHMMSS
  const timestamp = now
    .toISOString()
    .replace(/[-:]/g, "")
    .replace("T", "-")
    .substring(0, 15)
  const tagName = `andrew-mbp-${timestamp}-${shortSha}`
  const releaseName = `andrew-mbp - ${timestamp} (${shortSha})`

  const zipPath = path.join(process.cwd(), "dist", artifactName)

  console.log(`Creating release for commit: ${gitSha}`)
  console.log(`Tag: ${tagName}`)

  // Skip rather than fail when this exact tag was already released.
  const existing = sh.exec(
    `gh-axi release view ${tagName} --repo ${owner}/${repo};`,
    { silent: true },
  )
  if (existing.code === 0) {
    console.log(`Release ${tagName} already exists. Skipping.`)
    return
  }

  // gh-axi create takes the asset paths as trailing arguments, so the release
  // and its asset land in one call.
  await throwIfError(
    sh.exec(
      `gh-axi release create ${tagName} --repo ${owner}/${repo} --title "${releaseName}" --notes "Automated release for commit ${gitSha}" "${zipPath}";`,
      { silent: false },
    ),
  )

  console.log(`Release ${tagName} created with ${artifactName}.`)
}

export default run
