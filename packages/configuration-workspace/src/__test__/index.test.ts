import { createConfigurationApi } from "@ha/configuration-aggregate"
import {
  provisionedEnvConfiguration,
  sealedSecretEnvConfiguration,
} from "@ha/configuration-env-secrets"
import { when } from "jest-when"
jest.mock("@ha/configuration-aggregate")

describe("workspace configuration api.", () => {
  test("Created with provisioned and sealed secrets configuration APIs.", async () => {
    when(createConfigurationApi)
      .calledWith([provisionedEnvConfiguration, sealedSecretEnvConfiguration])
      .mockReturnValue("configurationApi")
    const sut = await import("../")
    expect(sut.default).toEqual("configurationApi")
  })
})
