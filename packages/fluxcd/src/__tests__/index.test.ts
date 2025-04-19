import { ChildProcess } from "child_process"
import { when } from "jest-when"
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
      get: jest.fn(),
    }
  })

  let flux
  beforeEach(() => {
    flux = fluxcd(configApi)
  })

  describe("exec", () => {
    test(`runs with the needed environment variables`, async () => {
      when(configApi.get).calledWith("env").mockResolvedValue("staging")
      when(configApi.get)
        .calledWith("github/username")
        .mockResolvedValue("github/username")
      when(configApi.get)
        .calledWith("github/token")
        .mockResolvedValue("github/token")

      await flux.exec("echo hello")

      const kubePath = path.resolve(
        __dirname,
        "../../../../resources/k8s/._secrets/staging/.kube/config",
      )
      expect(sh.exec).toHaveBeenCalledWith(
        "echo hello",
        expect.objectContaining({
          env: expect.objectContaining({
            GITHUB_USER: "github/username",
            GITHUB_TOKEN: "github/token",
            KUBECONFIG: kubePath,
          }),
        }),
      )
    })
  })
})
