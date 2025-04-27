import nodemon from "nodemon"
import path from "path"

const run = async () => {
  nodemon({
    verbose: true,
    ignore: ["*.test.js", "fixtures/*"],
    watch: [path.join(__dirname, "..", "src")],
    script: path.join(__dirname, "..", "src", "index.ts"),
    execMap: {
      js: "yarn node --require esbuild-register",
      ts: "yarn node --require esbuild-register",
      tsx: "yarn node --require esbuild-register",
    },
  })
    .on("start", () => {
      console.log("nodemon started")
    })
    .on("restart", (files) => {
      console.log("nodemon restarted")
    })
    .on("exit", () => {
      console.log("exiting")
    })
    .on("quit", () => console.log("quiting"))
    .on("crash", () => console.log("crashed"))
}

if (require.main === module) {
  run()
}

export default run
