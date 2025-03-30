import { configurationApi as EnvSecretsConfiguration } from "@ha/configuration-env-secrets"
import { logger } from "@ha/logger"
import sh from "shelljs"

type Item = {
  id: string
  title: string
  fields: { label: string; value: string; id: string }[]
}

const op = async (vaultId: string) => {
  sh.env["OP_API_TOKEN"] =
    await EnvSecretsConfiguration.get("onepassword/token")

  return {
    getItemByTitle: async (itemTitle: string): Promise<Item | null> => {
      try {
        const item = JSON.parse(
          sh.exec(
            `op item get "${itemTitle}" --vault "${vaultId}" --format json`,
            {
              silent: true,
            },
          ).stdout,
        )

        return item as Item
      } catch (error) {
        logger.debug(
          `CLI: Get item named ${itemTitle} failed. Error: ${error}.`,
        )
        return null
      }
    },
    updateItemByTitle: async (itemTitle: string, value: string) => {
      const { stderr, code } = sh.exec(
        `op item edit "${itemTitle}" "secret-value=${value}" --vault "${vaultId}"`,
      )
      if (code !== 0) {
        logger.debug(
          `CLI: Update item named ${itemTitle} failed. Exit code: ${code}. stderr: ${stderr}.`,
        )
        throw new Error(stderr)
      }
    },
    createItem: async (name: string, value: string) => {
      const { stderr, code } = sh.exec(
        `op item create --category "API Credential" --title "${name}" --vault "${vaultId}" 'secret-value=${value}'`,
      )
      if (code !== 0) {
        logger.debug(
          `CLI: item creation for item named ${name} failed. Exit code: ${code}. stderr: ${stderr}.`,
        )
        throw new Error(stderr)
      }
    },
  }
}

export { op }
export type { Item }
