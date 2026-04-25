import {
  onePasswordConfiguration,
  toOnePasswordReference,
} from "@ha/configuration-1password"
import { Tree } from "@nx/devkit"
import { execFile as execFileCb } from "node:child_process"
import { env } from "node:process"
import { promisify } from "node:util"

const execFile = promisify(execFileCb)

const toItemAndField = (
  secretName: string,
): { item: string; field: string } => {
  const parts = secretName.split("/")
  if (parts.length === 1) {
    return { item: secretName, field: "credential" }
  }
  return {
    item: parts.slice(0, -1).join("-"),
    field: parts[parts.length - 1],
  }
}

export async function secrets1passwordGenerator(_tree: Tree, _options: object) {
  const vault = env["OP_VAULT"]
  if (!vault) {
    throw new Error("OP_VAULT environment variable is not set.")
  }

  for (const secretName of onePasswordConfiguration.getNames()) {
    const reference = toOnePasswordReference(secretName, vault)
    const { item, field } = toItemAndField(secretName)

    let fieldAlreadyExists = false
    try {
      await execFile("op", ["read", "--no-newline", reference])
      fieldAlreadyExists = true
    } catch {
      // field or item does not exist
    }

    if (fieldAlreadyExists) {
      console.log(`Skipping ${secretName}: already exists in 1Password.`)
      continue
    }

    let itemAlreadyExists = false
    try {
      await execFile("op", ["item", "get", item, "--vault", vault])
      itemAlreadyExists = true
    } catch {
      // item does not exist
    }

    if (itemAlreadyExists) {
      await execFile("op", [
        "item",
        "edit",
        item,
        "--vault",
        vault,
        `${field}[text]=`,
      ])
      console.log(
        `Added field '${field}' to existing item '${item}' for ${secretName}.`,
      )
    } else {
      await execFile("op", [
        "item",
        "create",
        "--category",
        "API Credential",
        "--title",
        item,
        "--vault",
        vault,
        `${field}[text]=`,
      ])
      console.log(`Created item '${item}' with field '${field}' for ${secretName}.`)
    }
  }
}

export default secrets1passwordGenerator
