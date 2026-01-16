import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { Octokit } from "@octokit/core"
import { execSync } from "child_process"
import { createReadStream, statSync } from "fs"
import { join } from "path"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const token = await configurationApi.get("github/token")
  const owner = "andrew-codes"
  const repo = "home-ops"

  const gitSha = execSync("git rev-parse HEAD", { encoding: "utf-8" }).trim()
  const shortSha = gitSha.substring(0, 7)
  const tagName = `update-gaming-pc-${shortSha}`
  const releaseName = `Update Gaming PC - ${shortSha}`
  const artifactName = "update-gaming-pc.zip"

  const srcDir = join(process.cwd(), "src")
  const zipPath = join(process.cwd(), artifactName)

  console.log(`Creating release for commit: ${gitSha}`)
  console.log(`Tag: ${tagName}`)

  // Create zip of src directory (excluding config.json)
  console.log(`Zipping src directory...`)
  execSync(`zip -j "${zipPath}" "${srcDir}"/*.ps1`, { encoding: "utf-8" })

  const octokit = new Octokit({ auth: token })

  // Check if release already exists
  try {
    await octokit.request(
      `GET /repos/${owner}/${repo}/releases/tags/${tagName}`,
      {
        owner: owner,
        repo: repo,
        tag: tagName,
      },
    )
    console.log(`Release ${tagName} already exists. Skipping.`)
    return
  } catch (error: any) {
    if (error.status !== 404) {
      throw error
    }
  }

  // Create release
  console.log(`Creating GitHub release...`)
  const { data: release } = await octokit.request(
    `POST /repos/${owner}/${repo}/releases`,
    {
      owner: owner,
      repo: repo,
      tag_name: tagName,
      name: releaseName,
      body: `Automated release for commit ${gitSha}`,
      draft: false,
      prerelease: false,
    },
  )

  // Upload asset
  console.log(`Uploading ${artifactName}...`)
  const zipStats = statSync(zipPath)
  const zipStream = createReadStream(zipPath)

  await octokit.request(
    `POST https://uploads.github.com/repos/${owner}/${repo}/releases/${release.id}/assets?name=${artifactName}`,
    {
      owner: owner,
      repo: repo,
      release_id: release.id,
      name: artifactName,
      headers: {
        "content-type": "application/zip",
        "content-length": zipStats.size,
      },
      data: zipStream as any,
    },
  )

  // Clean up zip file
  execSync(`rm "${zipPath}"`)

  console.log(`Release created: ${release.html_url}`)
}

export default run
