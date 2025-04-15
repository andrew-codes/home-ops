import { createConfigApi as create1PasswordConfiguration } from "@ha/configuration-1password-cli"
import { ConfigurationApi } from "@ha/configuration-api"
import { configurationApi as envConfiguration } from "@ha/configuration-env-secrets"
import { when } from "jest-when"
import * as sut from ".."
jest.mock("@ha/configuration-1password-cli")
jest.mock("@ha/configuration-env-secrets")

describe("configuration api module exports", () => {
  const opConfiguration = jest.mocked<
    ConfigurationApi<{
      "onepassword/token": string
      "onepassword/server-url": string
      one: string
    }>
  >({
    get: jest.fn(),
    getNames: jest.fn(),
    set: jest.fn().mockReturnValue(null),
  })

  beforeEach(() => {
    when(envConfiguration.get)
      .calledWith("onepassword/vault-id")
      .mockResolvedValue("vault-id")
    when(create1PasswordConfiguration)
      .calledWith("vault-id")
      .mockResolvedValue(opConfiguration)
    opConfiguration.getNames.mockReturnValue([
      "onepassword/token",
      "onepassword/server-url",
      "one",
    ])
  })

  test("Created configuration API will throw error if configuration value cannot be found by name.", async () => {
    const api = await sut.createConfigurationApi()
    try {
      await api.get("mqtt/username")
    } catch (error) {
      expect(error).toBeInstanceOf(Error)
      expect((error as Error).message).toEqual(
        "Configuration value not found, mqtt/username.",
      )
    }
  })

  test("Created configuration API will return configuration value from the first provider that does not throw an error.", async () => {
    const api = await sut.createConfigurationApi([
      TestConfigProvider,
      TestConfigProvider2,
    ])

    const actual = await api.get("mqtt/username")
    expect(actual).toEqual("value")
  })

  test("Created configuration API defaults to providers (in order): env.", async () => {
    const api = await sut.createConfigurationApi()
    when(envConfiguration.get)
      .calledWith("mqtt/username")
      .mockRejectedValue(new Error("not found"))

    try {
      await api.get("mqtt/username")
    } catch (error) {}

    expect(opConfiguration.get).toHaveBeenCalledWith("mqtt/username")
  })

  test("Can get the names of all supported configuration by aggregating them from the providers.", async () => {
    const api = await sut.createConfigurationApi([
      TestConfigProvider,
      TestConfigProvider2,
    ])

    const actual = api.getNames()
    expect(actual).toEqual([
      "onepassword/token",
      "onepassword/server-url",
      "one",
    ])
  })

  test.only("Setting a value will set the value on all providers that support the value.", async () => {
    when(opConfiguration.set)
      .calledWith("onepassword/token", "test")
      .mockResolvedValue(null)
    const api = await sut.createConfigurationApi([
      TestConfigProvider,
      TestConfigProvider2,
    ])

    await api.set("onepassword/server-url", "test")

    expect(TestConfigProvider.set).not.toHaveBeenCalled()
    expect(TestConfigProvider2.set).toHaveBeenCalledWith(
      "onepassword/server-url",
      "test",
    )
    expect(opConfiguration.set).toHaveBeenCalledWith(
      "onepassword/server-url",
      "test",
    )
  })
})

const TestConfigProvider: ConfigurationApi<{ "onepassword/token": string }> = {
  get: async (name) => "value",
  getNames: () => ["onepassword/token"],
  set: jest.fn(),
}

const TestConfigProvider2: ConfigurationApi<{
  "onepassword/token": string
  "onepassword/server-url": string
}> = {
  get: async (name) => "different value",
  getNames: () => ["onepassword/token", "onepassword/server-url"],
  set: jest.fn(),
}
