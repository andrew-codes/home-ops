jest.mock("@ha/configuration-env-secrets")
jest.mock("../op")
jest.mock("@1password/connect")
import { configurationApi as EnvSecretsConfiguration } from "@ha/configuration-env-secrets"
import { when } from "jest-when"
import { createConfigApi } from "../"
import { op } from "../op"

const vaultId = "vault-id"
const getItemByTitle = jest.fn()
describe("configuration api module exports", () => {
  test("Uses the env-secrets configuration api to connect to 1Password and retrieve the value by name", async () => {
    when(EnvSecretsConfiguration.get)
      .calledWith("onepassword/token")
      .mockResolvedValue("token")
    when(EnvSecretsConfiguration.get)
      .calledWith("onepassword/vault-id")
      .mockResolvedValue(vaultId)
    when(op).calledWith(vaultId).mockResolvedValue({
      getItemByTitle,
    })
    when(getItemByTitle)
      .calledWith("k8s/ip")
      .mockResolvedValue({
        id: "123",
        title: "k8s/ip",
        fields: [{ label: "secret-value", value: "ipAddress" }],
      })

    const api = await createConfigApi(vaultId)
    const actual = await api.get("k8s/ip")
    expect(actual).toEqual({ id: "123", value: "ipAddress" })
  })
})
