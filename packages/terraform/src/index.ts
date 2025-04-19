import { logger } from "@ha/logger"
import { throwIfError } from "@ha/shell-utils"
import path from "path"
import sh from "shelljs"

const apply = async (
  vars?: Record<string, any> | undefined,
  cwd?: string | undefined,
  dataDir?: string | undefined,
): Promise<void> => {
  const env = {}
  for (const [key, value] of Object.entries(vars ?? {})) {
    env[`TF_VAR_${key}`] = value.toString()
  }
  const terraformDataDir = path.resolve(
    dataDir ?? path.join(process.cwd(), ".terraform"),
  )
  env["TF_DATA_DIR"] = path.join(terraformDataDir, ".terraform")

  logger.info("Applying terraform")
  await throwIfError(
    sh.exec(
      `terraform init --upgrade && terraform plan --out=terraform.plan && terraform apply "terraform.plan"`,
      {
        async: true,
        silent: true,
        cwd: cwd ?? process.cwd(),
        env: {
          ...process.env,
          ...env,
        },
      },
    ),
  )
}

export { apply }
