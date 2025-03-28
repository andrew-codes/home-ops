jest.mock("process", () => ({ chdir: jest.fn() }))
jest.mock("esbuild-register/dist/node")
jest.mock("@ha/configuration-workspace")
import type { ConfigurationApi } from "@ha/configuration-api"
import {
  Configuration,
  createConfigurationApi,
} from "@ha/configuration-workspace"
import { ExecutorContext } from "@nrwl/devkit"
import { register } from "esbuild-register/dist/node"
import path from "path"
import process from "process"
import executor from "../impl"

let ctx: ExecutorContext
beforeEach(() => {
  jest.resetModules()
})

beforeEach(() => {
  ctx = {
    cwd: "../",
    isVerbose: false,
    root: path.join(__dirname, "..", "..", "..", "..", ".."),
    workspace: { version: 2, projects: {} },
  } as unknown as ExecutorContext
})

test("Can require TS modules via esbuild-register.", async () => {
  await executor(
    {
      module: "scripts/deploy.ts",
      cwd: path.join("nx-executors", "src", "executors", "invoke", "__mocks__"),
    },
    ctx,
  )
  expect(register).toHaveBeenCalled()
})

test("Non-existant moodule files fail.", async () => {
  const { success } = await executor(
    {
      module: "scripts/deploy.ts",
      cwd: path.join("nx-executors", "src", "executors", "invoke", "__mocks__"),
    },
    ctx,
  )
  expect(success).toEqual(false)
})

test("Modules that do not export a function fail.", async () => {
  jest.doMock("deploy", () => ({}))
  const { success } = await executor(
    {
      module: "deploy",
      cwd: path.join("nx-executors", "src", "executors", "invoke", "__mocks__"),
    },
    ctx,
  )
  expect(success).toEqual(false)
})

test("Modules are resolved relative to the cwd option.", async () => {
  const deploy = jest.fn()
  jest.doMock(path.join(__dirname, "..", "__mocks__", "deploy.ts"), () => ({
    default: deploy,
  }))
  jest.mocked(createConfigurationApi).mockResolvedValue({
    configuration: true,
  } as unknown as ConfigurationApi<Configuration>)

  const { success } = await executor(
    {
      module: "./deploy.ts",
      cwd: path.join("nx-executors", "src", "executors", "invoke", "__mocks__"),
    },
    ctx,
  )
  expect(deploy).toBeCalled()
  expect(success).toEqual(true)
})

test("Modules default exported function will be invoked with the configuration API in the context of the provided cwd.", async () => {
  const deploy = jest.fn()
  jest.doMock(path.join(__dirname, "..", "__mocks__", "deploy.ts"), () => ({
    default: deploy,
  }))
  jest.mocked(createConfigurationApi).mockResolvedValue({
    configuration: true,
  } as unknown as ConfigurationApi<Configuration>)

  const { success } = await executor(
    {
      module: "./deploy.ts",
      cwd: path.join("nx-executors", "src", "executors", "invoke", "__mocks__"),
    },
    ctx,
  )
  expect(process.chdir).toBeCalledWith(
    path.resolve(
      __dirname,
      "..",
      "..",
      "..",
      "..",
      "..",
      "..",
      "packages",
      "nx-executors",
      "src",
      "executors",
      "invoke",
      "__mocks__",
    ),
  )
  expect(deploy).toBeCalledWith({ configuration: true }, ctx)
  expect(success).toEqual(true)
})
