import * as sut from ".."
import kubectl from "../kubectl"

test("exports eval", () => {
  expect(sut.kubectl).toEqual(kubectl)
})
