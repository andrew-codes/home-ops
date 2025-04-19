const shell = require("shelljs")
const fs = require("fs")
const path = require("path")
const { isEmpty } = require("lodash")

const kubeseal = (env, { namespace, name, secrets, savePath }) => {
  if (!env || !name || !savePath || isEmpty(secrets)) {
    throw new Error("Missing required parameters; env, name, savePath, secrets")
  }

  const KUBECONFIG = path.resolve(
    __dirname,
    `../../resources/k8s/._secrets/${env}/.kube/config`,
  )

  const { code, stdout, stderr } = shell.exec(
    `kubectl -n ${namespace ?? "default"} create secret generic ${name} ${secrets.join(" ")} --dry-run=client -o yaml`,
    { silent: true , env: { KUBECONFIG } },
  )

  if (code !== 0) {
    throw new Error(stderr)
  }

  console.debug(
    `echo -n "${stdout.toString()}" | kubeseal --format=yaml --cert=${path.join(__dirname, `../../../resources/sealed-secrets/keys/${env}.pub`)}`,
  )
  const kubesealOutput = shell.exec(
    `echo -n "${stdout.toString()}" | kubeseal --format=yaml --cert=${path.join(__dirname, `../../../resources/sealed-secrets/keys/${env}.pub`)}`,
    { silent: false, env: { KUBECONFIG } },
  )

  if (kubesealOutput.code !== 0) {
    throw new Error(kubesealOutput.stderr)
  }

  console.debug(kubesealOutput.stdout.toString())
  fs.writeFileSync(
    path.join(process.cwd(), "../../", savePath, `${name}-sealed.yaml`),
    kubesealOutput.stdout,
    "utf8",
  )
}

module.exports = kubeseal
