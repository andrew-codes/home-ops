import { safeCliString, safeCliStringWithDoubleQuotes } from "../utils"

describe("cli utils", () => {
  describe("safeCliString", () => {
    test("CLI safe string properly handles double quotes and new lines", () => {
      const input = `{
        "person"
      }`
      const expected = '{\\n        "person"\\n      }'
      const actual = safeCliString(input)

      expect(actual).toEqual(expected)
    })
  })

  describe("safeCliStringWithDoubleQuotes", () => {
    test("Safely handles double quotes", () => {
      const input = `{
        person1: {
            name: "Alice",
            welcome: "Hello " + self.name + "!",
        },
        person2: self.person1 { name: "Bob" },
    }`
      const expected = `{
        person1: {
            name: \"Alice\",
            welcome: \"Hello \" + self.name + \"!\",
        },
        person2: self.person1 { name: \"Bob\" },
    }`
      const actual = safeCliStringWithDoubleQuotes(input)

      expect(actual).toEqual(expected)
    })
  })
})
