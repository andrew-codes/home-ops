import { describe, expect, test } from "@jest/globals"
import { buildPlaybookCommand } from "../src/index"

describe("buildPlaybookCommand", () => {
  test("pins the python interpreter when no vars are given", () => {
    const command = buildPlaybookCommand("play.yml", ["10.0.0.1"])

    expect(command).toContain(
      `--extra-vars '{"ansible_python_interpreter":"/usr/bin/python3"}'`,
    )
    expect(command).toContain(`--inventory "10.0.0.1,"`)
  })

  test("keeps caller vars alongside the pinned interpreter", () => {
    const command = buildPlaybookCommand("play.yml", ["a", "b"], {
      observability_host: "10.0.0.2",
    })

    expect(command).toContain(`"ansible_python_interpreter":"/usr/bin/python3"`)
    expect(command).toContain(`"observability_host":"10.0.0.2"`)
    expect(command).toContain(`--inventory "a,b,"`)
  })

  test("lets a caller override the interpreter", () => {
    const command = buildPlaybookCommand("play.yml", ["a"], {
      ansible_python_interpreter: "/usr/bin/python3.11",
    })

    expect(command).toContain(
      `"ansible_python_interpreter":"/usr/bin/python3.11"`,
    )
    expect(command).not.toContain(`"/usr/bin/python3"`)
  })

  test("passes the private key when given", () => {
    expect(buildPlaybookCommand("play.yml", ["a"], {}, "/k")).toContain(
      "--private-key /k",
    )
  })
})
