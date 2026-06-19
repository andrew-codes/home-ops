import { ConfigurationApi } from "@ha/configuration-api"
import { when } from "jest-when"
import * as sut from ".."

describe("configuration api module exports", () => {
  const mockedProvider = jest.mocked<
    ConfigurationApi<{
      "onepassword/token": string
      "onepassword/server-url": string
      one: string
    }>
  >({
    get: jest.fn(),
    getNames: () => ["onepassword/token", "onepassword/server-url", "one"],
    set: jest.fn(),
  })
  const mockedSecondEnvProvider = jest.mocked<
    ConfigurationApi<{
      "k8s/ip": string
    }>
  >({
    get: jest.fn(),
    getNames: () => ["k8s/ip"],
    set: jest.fn(),
  })
  const mockedThirdProvider = jest.mocked<
    ConfigurationApi<{
      "k8s/ip": string
    }>
  >({
    get: jest.fn(),
    getNames: jest.fn(),
    set: jest.fn(),
  })

  beforeEach(() => {
    when(mockedThirdProvider.get)
      .calledWith("k8s/ip")
      .mockResolvedValue("k8s-ip")
    ;(mockedThirdProvider.getNames as jest.Mock).mockReturnValue(["k8s/ip"])
  })

  test("Created configuration API will throw error if configuration value cannot be found by name.", async () => {
    when(mockedProvider.get)
      .calledWith("onepassword/token")
      .mockRejectedValue("not found")
    const api = await sut.createConfigurationApi([
      mockedThirdProvider,
      mockedProvider,
    ])
    try {
      await api.get("onepassword/token")
    } catch (error) {
      expect(error).toBeInstanceOf(Error)
      expect((error as Error).message).toEqual(
        "Configuration value not found, onepassword/token.",
      )
    }
  })

  test("Created configuration API will return configuration value from the first provider that does not throw an error.", async () => {
    when(mockedSecondEnvProvider.get)
      .calledWith("k8s/ip")
      .mockResolvedValue("a different IP")
    const api = await sut.createConfigurationApi([
      mockedThirdProvider,
      mockedSecondEnvProvider,
    ])

    const actual = await api.get("k8s/ip")
    expect(actual).toEqual("k8s-ip")
  })

  test("Can get the names of all supported configuration by aggregating them from the providers.", () => {
    const api = sut.createConfigurationApi([
      mockedSecondEnvProvider,
      mockedProvider,
      mockedThirdProvider,
    ])

    const actual = api.getNames()
    expect(actual).toEqual([
      "k8s/ip",
      "onepassword/token",
      "onepassword/server-url",
      "one",
    ])
  })

  test("Setting a value will set the value on all providers that support the value.", async () => {
    const api = sut.createConfigurationApi([
      mockedThirdProvider,
      mockedProvider,
      mockedSecondEnvProvider,
    ])

    await api.set("k8s/ip", "test")

    expect(mockedThirdProvider.set).toHaveBeenCalledWith("k8s/ip", "test")
    expect(mockedProvider.set).not.toHaveBeenCalled()
    expect(mockedSecondEnvProvider.set).toHaveBeenCalledWith("k8s/ip", "test")
  })
})
