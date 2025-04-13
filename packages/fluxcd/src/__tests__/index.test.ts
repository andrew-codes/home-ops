import { ChildProcess } from "child_process"
import fs from "fs"
import path from "path"
import sh from "shelljs"
import fluxcd from ".."

jest.mock("shelljs", () => ({
  exec: jest.fn(),
  env: [],
}))
jest.mock("fs")
jest.mock("uuid")

describe("fluxcd", () => {
  beforeEach(() => {
    jest.resetAllMocks()
  })

  beforeEach(() => {
    jest.mocked(sh.exec).mockReturnValue({
      stderr: "",
      stdout: "",
      code: 0,
    } as unknown as ChildProcess)
  })

  let configApi
  beforeEach(() => {
    configApi = {
      get: jest.fn(async (key) => ({
        value: key,
      })),
    }
  })

  let flux
  beforeEach(() => {
    flux = fluxcd("kubeconfig\\nvalue", configApi)
  })

  describe("exec", () => {
    test(`saves kubeconfig to a file and sets its path as an environment variable`, () => {
      const { exec } = flux
      exec("echo hello")

      const kubePath = path.resolve(__dirname, "../../._secrets/.kube")
      expect(fs.mkdirSync).toHaveBeenCalledWith(kubePath, { recursive: true })
      expect(fs.writeFileSync).toHaveBeenCalledWith(
        path.join(kubePath, "config"),
        `kubeconfig
value`,
        {
          encoding: "utf8",
          mode: 0o600,
        },
      )
      expect(sh.env["KUBECONFIG"]).toBe(path.join(kubePath, "config"))
    })

    test(`runs with the GitHub environment variables`, () => {
      const { exec } = flux
      exec("echo hello")

      expect(sh.env["GITHUB_USER"]).toBe("github/username")
      expect(sh.env["GITHUB_TOKEN"]).toBe("github/token")
    })
  })
})
