const { execFileSync, spawn } = require("node:child_process");
const { copyFileSync, mkdirSync } = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const root = path.resolve(__dirname, "..");

async function prepareCliSidecar() {
  const dev = process.argv[2] === "--dev";
  const host = execFileSync("rustc", ["-vV"], { cwd: root, encoding: "utf8" })
    .match(/^host:\s*(\S+)/m)?.[1];
  if (!host) throw new Error("Could not determine the Rust host triple.");

  const target = process.env.TAURI_ENV_TARGET_TRIPLE || process.env.CARGO_BUILD_TARGET || host;
  const args = ["build", "--locked", "-p", "quotabar-cli", "--bin", "quotabar-cli",
    "--message-format=json-render-diagnostics"];
  if (!dev) args.push("--release");
  if (target !== host || process.env.CARGO_BUILD_TARGET) args.push("--target", target);

  const cargo = spawn("cargo", args, { cwd: root, stdio: ["ignore", "pipe", "inherit"] });
  const completed = new Promise((resolve, reject) => {
    cargo.once("error", reject);
    cargo.once("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`Cargo failed to build quotabar-cli (exit ${code}).`));
    });
  });
  let executable;
  const consumeOutput = async () => {
    for await (const line of readline.createInterface({ input: cargo.stdout })) {
      const message = JSON.parse(line);
      if (message.reason === "compiler-artifact" && message.target.name === "quotabar-cli") {
        executable = message.executable;
      } else if (message.reason === "compiler-message" && message.message.rendered) {
        process.stderr.write(message.message.rendered);
      }
    }
  };
  await Promise.all([consumeOutput(), completed]);
  if (!executable) throw new Error("Cargo did not report a quotabar-cli executable.");

  const binDir = path.join(root, "src-tauri", "binaries");
  const dest = path.join(binDir, `quotabar-cli-${target}${target.includes("windows") ? ".exe" : ""}`);
  mkdirSync(binDir, { recursive: true });
  copyFileSync(executable, dest);
  console.log(`==> CLI sidecar: ${dest}`);
}

prepareCliSidecar().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
