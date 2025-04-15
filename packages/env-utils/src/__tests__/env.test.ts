jest.mock("../utils", () => ({
  ...(jest.requireActual("../utils") as {}),
}))
jest.mock("detect-node")

import * as env from "../env"

beforeEach(() => {
  process.env = {}
})

test("isNode", () => {
  expect(env.isNode()).toEqual(true)
})

test("is browser/window", () => {
  expect(env.isBrowser()).toEqual(false)
})

test("is production", () => {
  process.env.NODE_ENV = "production"
  expect(env.isProd()).toEqual(true)
  process.env.NODE_ENV = "ppe"
  expect(env.isProd()).toEqual(false)
})

test("is test", () => {
  process.env.NODE_ENV = "test"
  expect(env.isTest()).toEqual(true)
  process.env.NODE_ENV = "development"
  expect(env.isTest()).toEqual(false)
})

test("is dev", () => {
  process.env.NODE_ENV = "development"
  expect(env.isDev()).toEqual(true)
  process.env.NODE_ENV = "test"
  expect(env.isDev()).toEqual(false)
})

describe("execute in env", () => {
  const execute = jest.fn()
  const noExecute = jest.fn()

  test("execute in dev only", () => {
    process.env.NODE_ENV = "development"
    env.excludeProd(execute)
    process.env.NODE_ENV = "test"
    env.devOnly(noExecute)
    expect(execute).toHaveBeenCalled()
    expect(noExecute).not.toHaveBeenCalled()
  })

  test("execute in prod only", () => {
    process.env.NODE_ENV = "production"
    env.prodOnly(execute)
    process.env.NODE_ENV = "ppe"
    env.prodOnly(noExecute)
    expect(execute).toHaveBeenCalled()
    expect(noExecute).not.toHaveBeenCalled()
  })

  test("execute in non prod only", () => {
    process.env.NODE_ENV = "integration"
    env.excludeProd(execute)
    process.env.NODE_ENV = "production"
    env.excludeProd(noExecute)
    expect(execute).toHaveBeenCalled()
    expect(noExecute).not.toHaveBeenCalled()
  })

  test("execute in non dev only", () => {
    process.env.NODE_ENV = "test"
    env.excludeDev(execute)
    process.env.NODE_ENV = "development"
    env.excludeDev(noExecute)
    expect(execute).toHaveBeenCalled()
    expect(noExecute).not.toHaveBeenCalled()
  })
})
