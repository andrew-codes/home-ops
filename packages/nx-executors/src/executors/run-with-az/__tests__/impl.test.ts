jest.mock("child_process")
import { ExecutorContext } from "@nx/devkit"
import { exec } from "child_process"
import executor from "../impl"

let ctx: ExecutorContext
beforeEach(() => {
  ctx = {
    cwd: "../",
    isVerbose: false,
    root: "./",
    workspace: { version: 2, projects: {} },
  }
})

test("Runs necessary commands to sign into az CLI prior to executing provided command.", () => {
  executor({ command: "ls" }, ctx)

  expect(exec).toHaveBeenCalledWith(
    expect.stringMatching(
      /^az login --service-principal --username \$AZURE_SERVICE_PRINCIPAL_APP_ID --password \$AZURE_SERVICE_PRINCIPAL_PASSWORD --tenant \$AZURE_SERVICE_PRINCIPAL_TENANT(.|\t|\n)+az account set --subscription \$AZURE_SUBSCRIPTION_ID(.|\t|\n)+ls/,
    ),
    { cwd: process.cwd() },
    expect.any(Function),
  )
})
