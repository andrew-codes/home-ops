import { env } from "node:process"

describe("configuration api module exports", () => {
  test("Configuration gets values from environment variables.", async () => {
    env["K8S_IP"] = "value"
    const { provisionedEnvConfiguration } = await import(
      "@ha/configuration-env-secrets"
    )

    const actual = await provisionedEnvConfiguration.get("k8s/ip")
    expect(actual).toEqual("value")
  })
})
