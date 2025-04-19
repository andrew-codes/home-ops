import type { ConfigurationApi } from "@ha/configuration-api"
import type { Configuration } from "@ha/configuration-workspace"
import { createSeal } from "@ha/github-secrets"
import { jsonnet } from "@ha/jsonnet"
import { kubectl } from "@ha/kubectl"
import path from "path"
import { name } from "./config"

const run = async (
  configurationApi: ConfigurationApi<Configuration>,
): Promise<void> => {
  const githubToken = await configurationApi.get("github/token")
  const kubeConfig = (await configurationApi.get("k8s/config")).value
  const kube = kubectl()

  await kube.exec(`kubectl create namespace actions-runner-system;`)
  await kube.exec(
    `kubectl delete secret controller-manager --namespace=actions-runner-system;`,
  )

  await kube.exec(
    `kubectl create secret generic controller-manager --namespace=actions-runner-system --from-literal=github_token="${githubToken.value}";`,
  )

  await kube.exec(
    `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.8.0/cert-manager.yaml;`,
  )

  await kube.exec(
    `kubectl create -f https://github.com/actions-runner-controller/actions-runner-controller/releases/download/v0.27.6/actions-runner-controller.yaml;`,
  )
  const seal = createSeal(githubToken.value)

  const secrets: Array<keyof Configuration> = [
    "onepassword/server-url",
    "onepassword/token",
    "onepassword/vault-id",
    "code-cov/token",
  ]
  const names: string[] = [
    "ONEPASSWORD_SERVER_URL",
    "ONEPASSWORD_TOKEN",
    "ONEPASSWORD_VAULT_ID",
    "CODE_COV_TOKEN",
  ]

  const registry = await configurationApi.get("docker-registry/hostname")
  const repo_owner = await configurationApi.get("repository/owner")
  const repo_name = await configurationApi.get("repository/name")
  let otherRepoNames: string[] = []
  try {
    otherRepoNames =
      (await (
        await configurationApi.get("repository/other/names")
      ).value.split(",")) ?? []
  } catch (e) {
    otherRepoNames = []
  }

  const repoNames = [repo_name.value].concat(otherRepoNames)

  await Promise.all(
    repoNames.map((repoName) =>
      Promise.all(
        secrets.map(async (secretName, index) => {
          const secretValue = await configurationApi.get(secretName)

          return await seal(
            repo_owner.value,
            repoName,
            names[index],
            typeof secretValue === "string" ? secretValue : secretValue.value,
          )
        }),
      ),
    ),
  )

  await Promise.all(
    repoNames.map((repoName) =>
      seal(
        repo_owner.value,
        repoName,
        "JEST_REPORTER_TOKEN",
        githubToken.value,
      ),
    ),
  )

  const jsonnetOutputs = (
    await Promise.all(
      repoNames.map((repoName) =>
        jsonnet.eval(
          path.join(__dirname, "..", "deployment", "index.jsonnet"),
          {
            image: `${registry.value}/${name}:latest`,
            repoName: `${repo_owner.value}/${repoName}`,
            name: repoName,
          },
        ),
      ),
    )
  ).map((jsonnetOutput) => JSON.parse(jsonnetOutput))

  await Promise.all(
    jsonnetOutputs.flatMap((resources) =>
      resources.map(async (resource) =>
        kube.applyToCluster(JSON.stringify(resource)),
      ),
    ),
  )

  // Playnite web
  Promise.all(
    await Promise.all(
      secrets.map(async (secretName, index) => {
        const secretValue = await configurationApi.get(secretName)

        return await seal(
          repo_owner.value,
          "playnite-web",
          names[index],
          typeof secretValue === "string" ? secretValue : secretValue.value,
        )
      }),
    ),
  )
  await seal(
    repo_owner.value,
    "playnite-web",
    "JEST_REPORTER_TOKEN",
    githubToken.value,
  )

  const playniteWebJsonOutputs = JSON.parse(
    await jsonnet.eval(
      path.join(__dirname, "..", "deployment", "index.jsonnet"),
      {
        image: `ghcr.io/andrew-codes/playnite-web-gh-action-runner:3-dev`,
        repoName: `${repo_owner.value}/playnite-web`,
        name: "playnite-web",
      },
    ),
  )

  await Promise.all(
    playniteWebJsonOutputs.flatMap((resource) =>
      kube.applyToCluster(JSON.stringify(resource)),
    ),
  )

  await kube.rolloutDeployment("restart", "controller-manager", {
    namespace: "actions-runner-system",
  })
}

export default run
