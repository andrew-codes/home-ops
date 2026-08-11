import { throwIfError } from "@ha/shell-utils"
import fs from "fs/promises"
import path from "path"
import sh from "shelljs"

const artifactName = "andrew-mbp"

/**
 * Gathers everything the setup needs into dist/andrew-mbp, then zips it to
 * dist/andrew-mbp.zip.
 *
 * The packaged directory has to stand on its own: it is what a release asset
 * unzips to on a machine that has never cloned home-ops. Nothing copied in may
 * reference the monorepo, a sibling project, or the Nx workspace layout.
 */
const run = async (): Promise<void> => {
  const projectRoot = path.join(__dirname, "..")
  const distPath = path.join(projectRoot, "dist")
  const packagedPath = path.join(distPath, artifactName)

  await fs.rm(distPath, { recursive: true, force: true })
  await fs.mkdir(packagedPath, { recursive: true })

  // src/ holds the whole self-contained payload: the flake and its lock, the
  // nix modules, and setup.sh.
  await fs.cp(path.join(projectRoot, "src"), packagedPath, { recursive: true })

  // The README ships inside the artifact too, so the manual steps macOS forces
  // are readable from the unzipped directory rather than only on GitHub.
  await fs.cp(
    path.join(projectRoot, "README.md"),
    path.join(packagedPath, "README.md"),
  )

  // git preserves the exec bit, but fs.cp does not depend on that holding.
  await fs.chmod(path.join(packagedPath, "setup.sh"), 0o755)

  // Zip with the andrew-mbp/ prefix intact, so unzipping produces one
  // directory to cd into rather than loose files in the download folder.
  await throwIfError(
    sh.exec(
      `cd "${distPath}" && zip -q -r "${artifactName}.zip" "${artifactName}";`,
      {
        silent: false,
      },
    ),
  )
}

export default run
