import { createConfigurationApi } from "@ha/configuration-aggregate"
import { onePasswordConfiguration } from "@ha/configuration-1password"
import { when } from "jest-when"
jest.mock("@ha/configuration-aggregate")

describe("workspace configuration api.", () => {
  test("Created with 1password and env configuration APIs.", async () => {
    when(createConfigurationApi)
      .calledWith(
        expect.arrayContaining([
          onePasswordConfiguration,
          expect.objectContaining({ getNames: expect.any(Function) }),
        ]),
      )
      .mockReturnValue("configurationApi")
    const sut = await import("../")
    expect(sut.default).toEqual("configurationApi")
  })
})
