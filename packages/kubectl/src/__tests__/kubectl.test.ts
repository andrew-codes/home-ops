jest.mock("shelljs", () => ({
  exec: jest.fn(),
  env: [],
}))
jest.mock("fs/promises")
jest.mock("uuid")
import { ChildProcess } from "child_process"
import fs from "fs/promises"
import sh from "shelljs"
import { v4 as uuidv4 } from "uuid"
import kubectl from "../kubectl"

describe("kubectl", () => {
  beforeEach(() => {
    jest.resetAllMocks()
  })

  beforeEach(() => {
    jest
      .mocked(sh.exec)
      .mockReturnValue({
        stderr: "",
        stdout: "",
        code: 0,
      } as unknown as ChildProcess)
  })

  let kube
  beforeEach(() => {
    kube = kubectl("kubeconfig")
  })

  describe("applyToCluster", () => {
    test(`Applies content to k8s cluster via kubectl CLI.
- Writes to input to file to avoid commands that exceed the allowed length.`, async () => {
      const input = `{
        "person"
      }`
      uuidv4.mockReturnValue("uuid")

      await kube.applyToCluster(input)

      expect(fs.writeFile).toHaveBeenCalledWith("/tmp/uuid", input)
      expect(sh.exec).toHaveBeenCalledWith(
        expect.stringMatching(
          /kubectl apply --namespace default -f \/tmp\/uuid;/,
        ),
        { silent: false, shell: "/bin/bash" },
      )
    })
  })

  describe("rolloutDeployment", () => {
    test("Invokes kubectl rollout with proper CLI parameters.", async () => {
      await kube.rolloutDeployment("restart", "deployment.name")

      expect(sh.exec).toHaveBeenCalledWith(
        `kubectl -n default rollout restart deployment deployment.name;`,
        { silent: true },
      )
    })

    test("Deployments can be in a non-default namespace.", async () => {
      await kube.rolloutDeployment("restart", "deployment.name", {
        namespace: "ns",
      })

      expect(sh.exec).toHaveBeenCalledWith(
        `kubectl -n ns rollout restart deployment deployment.name;`,
        { silent: true },
      )
    })
  })
})
