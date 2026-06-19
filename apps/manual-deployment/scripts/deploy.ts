import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { isEmpty } from "lodash"
import { Octokit } from "@octokit/core"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const projects = JSON.parse(process.argv[2])
    .overrides["target-projects"].split(",")
    .filter((project) => !isEmpty(project))
  if (isEmpty(projects)) {
    throw new Error(
      "No target projects specified. Did you forget `--target-projects=p1,p2`. ",
    )
  }

  console.log(`Deploying projects: ${projects.join(",")}`)
  const token = await configurationApi.get("github/token")
  const owner = await configurationApi.get("repository/owner")
  const repo = await configurationApi.get("repository/name")
  const octokit = new Octokit({
    auth: token,
  })
  await octokit.request(`POST /repos/${owner}/${repo}/dispatches`, {
    event_type: "manual-deploy",
    client_payload: {
      projects: projects.join(","),
    },
  })
}

export default run
