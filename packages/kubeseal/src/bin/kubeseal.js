const kubeseal = require("../kubeseal")
const yargs = require("yargs/yargs")
const { hideBin } = require("yargs/helpers")
const { isEmpty } = require("lodash")

yargs(hideBin(process.argv))
  .command(
    "generic name",
    "seal a generic secret for a given k8s environment",
    (yargs) => {
      return yargs.positional("name", {
        describe: "name of generic secret",
      })
    },
    (argv) => {
      const secrets = (argv.fromLiteral ?? [])
        .map((item) => `--from-literal=${item}`)
        .concat((argv.fromFile ?? []).map((item) => `--from-file=${item}`))

      if (isEmpty(secrets)) {
        throw new Error(
          "Missing required parameters; --from-literal or --from-file",
        )
      }

      kubeseal(argv.env, {
        namespace: argv.namespace,
        name: argv.name,
        savePath: argv.savePath,
        secrets,
      })
    },
  )
  .option("env", {
    type: "string",
    description:
      "K8s environment name; used to look up the environment's public key.",
  })
  .option("from-literal", {
    type: "array",
    description: "Secret value as literal value.",
    requiresArg: false,
  })
  .option("from-file", {
    type: "array",
    description: "Secret value as literal value.",
    requiresArg: false,
  })
  .option("savePath", {
    type: "string",
    description:
      "Path to save the encrypted secret; relative to current working directory.",
  })
  .option("namespace", {
    alias: "n",
    type: "string",
    requiresArg: false,
    description: "K8s namespace to store secret.",
    default: "default",
  })
  .parse()
