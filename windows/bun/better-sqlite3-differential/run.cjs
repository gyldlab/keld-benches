const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const here = __dirname;
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(path.join(here, file))).digest("hex");
const runs = [["bun", "better-sqlite3-13"], ["bun", "better-sqlite3-12"], ["node", "better-sqlite3-13"], ["node", "better-sqlite3-12"]].map(([runtime, pkg]) => {
  const result = spawnSync(runtime, ["probe.cjs", pkg], { cwd: here, encoding: "utf8" });
  return { command: `${runtime} probe.cjs ${pkg}`, exit_code: result.status, stdout: result.stdout, stderr: result.stderr };
});
const receipt = { schema: "kel215.native-addon-receipt/v1", fixture_sha256: hash("probe.cjs"), lock_sha256: hash("bun.lock"), package_sha256: hash("package.json"), runtimes: { bun: spawnSync("bun", ["--revision"], { encoding: "utf8" }).stdout.trim(), node: process.version }, runs };
const out = path.join(here, "results", "2026-09-11.windows-x64.raw.json");
fs.writeFileSync(out, JSON.stringify(receipt, null, 2) + "\n");
if (runs.some((run) => run.command.includes("better-sqlite3-13") && run.command.startsWith("bun") && run.exit_code !== 0) || runs.some((run) => run.command.includes("better-sqlite3-12") && run.command.startsWith("bun") && run.exit_code === 0)) process.exitCode = 1;
