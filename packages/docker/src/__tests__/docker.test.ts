jest.mock("shelljs", () => ({
  exec: jest.fn(),
}))
import { ConfigurationApi } from "@ha/configuration-api"
import { Configuration } from "@ha/configuration-workspace"
import { when } from "jest-when"
import sh from "shelljs"
import { createClient } from "../docker"

describe("docker", () => {
  const get = jest.fn()
  beforeEach(() => {
    jest.mocked(sh.exec).mockReturnValue({ stderr: "", stdout: "", code: 0 })
    when(sh.exec)
      .calledWith(expect.stringContaining("docker login"), { silent: true })
      .mockReturnValue({ stderr: "", stdout: "", code: 0 })
    when(get)
      .calledWith("docker-registry/username")
      .mockResolvedValue({ value: "username" })
    when(get)
      .calledWith("docker-registry/password")
      .mockResolvedValue({ value: "password" })
  })

  test("Failures to authenticate throw an error", async () => {
    when(sh.exec)
      .calledWith(expect.stringContaining("docker login"), expect.anything())
      .mockReturnValue({ stderr: "error", stdout: "", code: 1 })
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await expect(docker.pushImage("some/imageName:latest")).rejects.toThrow(
      "error",
    )
  })

  test("Building a docker image proxies to the docker CLI.", async () => {
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await docker.build("some/imageName:latest")

    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(/^docker buildx build.*/),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--build-arg OWNER=username"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--build-arg REPO=home-ops"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--load"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--platform linux/amd64"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("-t ghcr.io/some/imageName:latest"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(/.* -f Dockerfile;$/),
      expect.anything(),
    )
  })

  test("Building a docker image with custom context.", async () => {
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await docker.build("some/imageName:latest", {
      context: "..some/directory",
    })

    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(/^docker buildx build.*/),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--build-arg OWNER=username"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--build-arg REPO=home-ops"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--load"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--platform linux/amd64"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("-t ghcr.io/some/imageName:latest"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(/.* \.\.some\/directory -f Dockerfile;$/),
      expect.anything(),
    )
  })

  test("Building a docker image with custom dockerfile.", async () => {
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await docker.build("some/imageName:latest", {
      dockerFile: "aFile",
    })

    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(/^docker buildx build.*/),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--build-arg OWNER=username"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--build-arg REPO=home-ops"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--load"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("--platform linux/amd64"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringContaining("-t ghcr.io/some/imageName:latest"),
      expect.anything(),
    )
    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(/.* -f aFile;$/),
      expect.anything(),
    )
  })

  test("Docker build CLI errors throw error.", async () => {
    when(sh.exec)
      .calledWith(expect.stringContaining("docker build"), expect.anything())
      .mockReturnValue({ stderr: "error", stdout: "", code: 1 })
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await expect(docker.build("some/imageName:latest")).rejects.toThrow("error")
  })

  test("Pushing an image to a registry proxy to the docker CLI.", async () => {
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await docker.pushImage("some/imageName:latest")

    expect(sh.exec).toHaveBeenCalledWith(
      expect.stringMatching(
        /^docker login (.*--username username)|(.*--password password)/,
      ),
      expect.anything(),
    )

    expect(sh.exec).toHaveBeenCalledWith(
      `docker push ghcr.io/some/imageName:latest;`,
      expect.anything(),
    )
  })

  test("Docker push CLI errors throw error.", async () => {
    when(sh.exec)
      .calledWith(expect.stringContaining("docker push"), expect.anything())
      .mockReturnValue({ stderr: "error", stdout: "", code: 1 })
    const docker = await createClient({
      get,
    } as unknown as ConfigurationApi<Configuration>)

    await expect(docker.pushImage("some/imageName:latest")).rejects.toThrow(
      "error",
    )
  })
})
