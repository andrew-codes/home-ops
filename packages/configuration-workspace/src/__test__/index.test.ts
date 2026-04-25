import { createConfigurationApi } from "@ha/configuration-aggregate"
import { onePasswordConfiguration } from "@ha/configuration-1password"
import { when } from "jest-when"
jest.mock("@ha/configuration-aggregate")

describe("workspace configuration api.", () => {
  test("Created with 1password configuration API.", async () => {
    when(createConfigurationApi)
      .calledWith([onePasswordConfiguration])
      .mockReturnValue("configurationApi")
    const sut = await import("../")
    expect(sut.default).toEqual("configurationApi")
  })
})
