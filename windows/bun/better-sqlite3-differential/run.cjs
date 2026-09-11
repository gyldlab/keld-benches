const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const here = __dirname;
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(path.join(here, file))).digest("hex");
if (process.platform !== "win32" || process.arch !== "x64") throw new Error("KEL-215 receipt requires Windows x64");
const runs = [["bun", "better-sqlite3-13"], ["bun", "better-sqlite3-12"], ["node", "better-sqlite3-13"], ["node", "better-sqlite3-12"]].map(([runtime, pkg]) => {
  const result = spawnSync(runtime, ["probe.cjs", pkg], { cwd: here, encoding: "utf8" });
  return { command: `${runtime} probe.cjs ${pkg}`, exit_code: result.status, stdout: result.stdout, stderr: result.stderr };
});
const receipt = { schema: "kel215.native-addon-receipt/v1", fixture_sha256: hash("probe.cjs"), lock_sha256: hash("bun.lock"), package_sha256: hash("package.json"), runtimes: { bun: spawnSync("bun", ["--revision"], { encoding: "utf8" }).stdout.trim(), node: process.version }, runs };
const out = path.join(here, "results", "2026-09-11.windows-x64.raw.json");
fs.writeFileSync(out, JSON.stringify(receipt, null, 2) + "\n");
const by = (command) => runs.find((run) => run.command === command);
const json = (run) => { try { return JSON.parse(run.stdout); } catch { return null; } };
const bun13 = json(by("bun probe.cjs better-sqlite3-13"));
const bun12 = json(by("bun probe.cjs better-sqlite3-12"));
const node13 = json(by("node probe.cjs better-sqlite3-13"));
const node12 = json(by("node probe.cjs better-sqlite3-12"));
const valid = bun13 && node13 && node12 && bun12 && by("bun probe.cjs better-sqlite3-13").exit_code === 0 && by("bun probe.cjs better-sqlite3-12").exit_code === 1 && by("node probe.cjs better-sqlite3-13").exit_code === 0 && by("node probe.cjs better-sqlite3-12").exit_code === 0 && bun12.attempted_load === "failed" && bun12.error_code === "ERR_DLOPEN_FAILED" && bun12.selected_artifact && node13.teardown === "closed" && node12.teardown === "closed";
if (!valid) process.exitCode = 1;
if (!process.exitCode) {
  const digest = crypto.createHash("sha256").update(fs.readFileSync(out)).digest("hex");
  const summary = { fixture: "kel215-better-sqlite3-differential", platform: "windows", arch: "x86_64", receipt_sha256: digest, runs: [bun13, bun12, node13, node12] };
  fs.writeFileSync(path.join(here, "results", "2026-09-11.windows-x64.json"), JSON.stringify(summary, null, 2) + "\n");
  for (const [version, record] of [["13.0.3", bun13], ["12.11.1", bun12]]) {
    const pass = version === "13.0.3";
    const artifact = record.selected_artifact;
    const evidence = { schema: "keld.compat.evidence/v1", artifact: { sha256: `sha256:${artifact.sha256}`, platform: "windows", arch: "x86_64" }, revisions: { keld: "de40149247fe9b410ba4954da167a445393f812c", bun: receipt.runtimes.bun, engine: `better-sqlite3-${version}` }, authority_profile: "legacy_sandbox_off", operation: { id: "native-addon.better-sqlite3.sql-callback-teardown", kind: "primary_workflow", oracle: { id: "sql-callback-result-negative-query-and-close", revision: "kel215-windows-v1" } }, result: pass ? "pass" : "fail", evidence_uri: `sha256:${digest}` };
    fs.writeFileSync(path.join(here, "evidence", `better-sqlite3-${version}-bun-1.4.2.json`), JSON.stringify(evidence, null, 2) + "\n");
  }
}
