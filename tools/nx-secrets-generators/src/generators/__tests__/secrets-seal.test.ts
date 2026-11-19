import { sealedOnePasswordConfiguration } from "@ha/configuration-1password"
import { spawnSync } from "node:child_process"
import { Tree } from "@nx/devkit"
import { createTreeWithEmptyWorkspace } from "@nx/devkit/testing"
import { uniq } from "lodash"
import { SecretsGeneratorSchema } from "../schema"
import { secretsSealGenerator } from "../secrets-seal"

jest.mock("@ha/configuration-1password", () => {
  const names = [
    "dummy-app/token",
    "dummy-app/other",
    "regcred/email",
    "regcred/password",
    "regcred/server",
    "regcred/username",
    "tailscale-operator-oauth/client-id",
    "tailscale-operator-oauth/client-secret",
  ]
  return {
    sealedOnePasswordConfiguration: {
      getNames: () => names,
      get: async (name: string) => `dummy-value-of-${name.replace("/", "-")}`,
      set: jest.fn(),
    },
  }
})

const hasBinary = (name: string) => spawnSync("which", [name]).status === 0

//  These tests can only be run locally as they require a kubectl context and 1Password CLI.
describe("secrets-seal generator", () => {
  let tree: Tree
  const options: SecretsGeneratorSchema = { env: "production" }

  beforeEach(() => {
    tree = createTreeWithEmptyWorkspace()
  })

  test.skip("should create sealed k8s secret file for each k8s secret.", async () => {
    await secretsSealGenerator(tree, options)

    expect(
      tree.exists(`./infrastructure/${options.env}/secrets/kustomization.yaml`),
    ).toBe(true)
    expect(
      tree
        .read(`./infrastructure/${options.env}/secrets/kustomization.yaml`)
        ?.toString(),
    ).toEqual(`resources:
${uniq(
  sealedOnePasswordConfiguration.getNames().map((name) => {
    return name.split("/").shift()
  }),
)
  .map((k8sSecretName) => {
    return `  - ${k8sSecretName}-sealed.yaml`
  })
  .join("\n")}`)

    sealedOnePasswordConfiguration.getNames().forEach((name) => {
      const k8sSecretName = name.split("/").shift()
      expect(
        tree.exists(
          `./infrastructure/${options.env}/secrets/${k8sSecretName}-sealed.yaml`,
        ),
      ).toBe(true)
    })
  })
})

// Runs the real kubectl and kubeseal with the repo's public sealing keys and
// dummy values. The @ha/kubectl wrapper points KUBECONFIG at a file that does
// not exist, so there is no kubeconfig context, as on a fresh machine. Skipped
// where the two binaries are not installed.
const describeWithBinaries =
  hasBinary("kubectl") && hasBinary("kubeseal") ? describe : describe.skip

describeWithBinaries("secrets-seal generator without a kubeconfig", () => {
  let consoleError: jest.SpyInstance

  beforeEach(() => {
    consoleError = jest
      .spyOn(console, "error")
      .mockImplementation(() => undefined)
  })

  afterEach(() => {
    consoleError.mockRestore()
  })

  test.each(["production"])(
    "seals every secret into the default namespace for %s.",
    async (env) => {
      const tree = createTreeWithEmptyWorkspace()
      tree.write(
        `infrastructure/${env}/tailscale-operator/kustomization.yaml`,
        "resources:\n  - ../../base/tailscale-operator\n",
      )
      await secretsSealGenerator(tree, { env })

      // kubeseal refuses a secret that does not declare a namespace, in which
      // case the generator logs the error and writes no file.
      expect(consoleError).not.toHaveBeenCalled()
      for (const secret of ["dummy-app", "regcred"]) {
        const sealed = tree
          .read(`infrastructure/${env}/secrets/${secret}-sealed.yaml`)
          ?.toString()
        expect(sealed).toBeDefined()
        expect(sealed).toMatch(/^kind: SealedSecret$/m)
        expect(sealed).toMatch(new RegExp(`^  name: ${secret}$`, "m"))
        // Once under metadata and once under spec.template.metadata.
        expect(sealed?.match(/^ {2,6}namespace: default$/gm)).toHaveLength(2)
        expect(sealed).not.toContain("dummy-value-of-")
      }
    },
  )

  test("seals a secret for another namespace next to the Kustomization that creates it.", async () => {
    const env = "production"
    const tree = createTreeWithEmptyWorkspace()
    const kustomizationPath = `infrastructure/${env}/tailscale-operator/kustomization.yaml`
    tree.write(
      kustomizationPath,
      `# A comment.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/tailscale-operator
`,
    )
    await secretsSealGenerator(tree, { env })
    // A second run must not list the sealed file twice.
    await secretsSealGenerator(tree, { env })

    expect(consoleError).not.toHaveBeenCalled()
    const sealed = tree
      .read(
        `infrastructure/${env}/tailscale-operator/tailscale-operator-oauth-sealed.yaml`,
      )
      ?.toString()
    expect(sealed).toMatch(/^kind: SealedSecret$/m)
    expect(sealed).toMatch(/^ {2}name: tailscale-operator-oauth$/m)
    expect(sealed?.match(/^ {2,6}namespace: tailscale$/gm)).toHaveLength(2)
    expect(sealed).toMatch(/^ {4}client-id: /m)
    expect(sealed).toMatch(/^ {4}client-secret: /m)
    expect(tree.read(kustomizationPath)?.toString()).toEqual(`# A comment.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/tailscale-operator
  - tailscale-operator-oauth-sealed.yaml
`)

    // The shared secrets directory must not apply a secret whose namespace is
    // created by another Kustomization.
    expect(
      tree.exists(
        `infrastructure/${env}/secrets/tailscale-operator-oauth-sealed.yaml`,
      ),
    ).toBe(false)
    expect(
      tree.read(`infrastructure/${env}/secrets/kustomization.yaml`)?.toString(),
    ).not.toContain("tailscale-operator-oauth")
  })
})
