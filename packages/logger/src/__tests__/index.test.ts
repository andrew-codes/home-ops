import * as sut from "../"
import { logger } from "../createLogger"

describe("logger", () => {
  test("exports create logger", () => {
    expect(sut.logger).toEqual(logger)
  })
})
