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
    await expect(api.get("onepassword/token")).rejects.toThrow(
      /^Configuration value not found, onepassword\/token\./,
    )
  })

  test("The not found error includes the underlying error of every failing provider.", async () => {
    const first = jest.mocked<ConfigurationApi<{ "k8s/ip": string }>>({
      get: jest.fn().mockRejectedValue(new Error("op: not signed in")),
      getNames: () => ["k8s/ip"],
      set: jest.fn(),
    })
    const second = jest.mocked<ConfigurationApi<{ "k8s/ip": string }>>({
      get: jest.fn().mockRejectedValue("plain string failure"),
      getNames: () => ["k8s/ip"],
      set: jest.fn(),
    })
    const api = sut.createConfigurationApi([first, second])

    await expect(api.get("k8s/ip")).rejects.toThrow(
      /^Configuration value not found, k8s\/ip\.[\s\S]*op: not signed in[\s\S]*plain string failure/,
    )
  })

  test("The not found error has no provider details when no provider supports the name.", async () => {
    const api = sut.createConfigurationApi([mockedSecondEnvProvider])

    await expect(api.get("one" as never)).rejects.toThrow(
      /^Configuration value not found, one\.$/,
    )
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
