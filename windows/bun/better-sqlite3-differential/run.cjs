const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const here = __dirname;
const MATRIX = [
  { runtime: "bun", alias: "better-sqlite3-13", version: "13.0.3", expectedExit: 0 },
  { runtime: "bun", alias: "better-sqlite3-12", version: "12.11.1", expectedExit: 1 },
  { runtime: "node", alias: "better-sqlite3-13", version: "13.0.3", expectedExit: 0 },
  { runtime: "node", alias: "better-sqlite3-12", version: "12.11.1", expectedExit: 0 },
];

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function fileHash(root, file, io = fs) {
  return sha256(io.readFileSync(path.join(root, file)));
}

function freshRunId(now = new Date(), pid = process.pid) {
  return `${now.toISOString().replace(/[-:.]/g, "")}-${pid}`;
}

function outputPaths(root, runId) {
  return {
    raw: path.join(root, "results", `${runId}.windows-x64.raw.json`),
    summary: path.join(root, "results", `${runId}.windows-x64.json`),
    evidence13: path.join(root, "evidence", `${runId}.better-sqlite3-13.0.3-bun.json`),
    evidence12: path.join(root, "evidence", `${runId}.better-sqlite3-12.11.1-bun.json`),
  };
}

function assertFresh(paths, io = fs) {
  const used = Object.values(paths).filter((candidate) => io.existsSync(candidate));
  if (used.length > 0) {
    throw new Error(`refusing to reuse output set; choose a fresh run id: ${used.join(", ")}`);
  }
}

function normalizeSpawn(command, args, options, spawn = spawnSync) {
  try {
    const result = spawn(command, args, { ...options, encoding: "utf8" });
    return {
      command: [command, ...args].join(" "),
      exit_code: result.status ?? null,
      signal: result.signal ?? null,
      spawn_error: result.error ? {
        code: result.error.code ?? null,
        message: result.error.message ?? String(result.error),
      } : null,
      stdout: typeof result.stdout === "string" ? result.stdout : "",
      stderr: typeof result.stderr === "string" ? result.stderr : "",
    };
  } catch (error) {
    return {
      command: [command, ...args].join(" "),
      exit_code: null,
      signal: null,
      spawn_error: { code: error.code ?? null, message: error.message ?? String(error) },
      stdout: "",
      stderr: "",
    };
  }
}

function parseJsonOutput(run) {
  if (!run || run.spawn_error || run.signal || typeof run.stdout !== "string") return null;
  try {
    return JSON.parse(run.stdout);
  } catch {
    return null;
  }
}

function validArtifact(value) {
  return value && typeof value.path === "string" && value.path.endsWith(".node") &&
    typeof value.sha256 === "string" && /^[0-9a-f]{64}$/.test(value.sha256);
}

function sameArtifact(selected, loaded) {
  return validArtifact(selected) && validArtifact(loaded) &&
    selected.path === loaded.path && selected.sha256 === loaded.sha256;
}

function validatePositive(value, expected, revision) {
  return Boolean(value &&
    value.package === "better-sqlite3" &&
    value.version === expected.version &&
    value.runtime === expected.runtime &&
    value.runtime_revision === revision &&
    value.query_callback_result === 42 &&
    value.negative_control === "SQLITE_ERROR" &&
    value.teardown === "closed" &&
    sameArtifact(value.selected_artifact, value.artifact));
}

function validateExpectedFailure(value, expected, revision) {
  return Boolean(value &&
    value.package === "better-sqlite3" &&
    value.version === expected.version &&
    value.runtime === expected.runtime &&
    value.runtime_revision === revision &&
    validArtifact(value.selected_artifact) &&
    value.artifact === undefined &&
    value.attempted_load === "failed" &&
    value.error_code === "ERR_DLOPEN_FAILED" &&
    typeof value.error === "string" && value.error.length > 0);
}

function runtimeRevision(query, runtime) {
  if (!query || query.exit_code !== 0 || query.signal || query.spawn_error || query.stderr !== "") return null;
  if (runtime === "node") {
    const revision = query.stdout.trim();
    return /^v\d+\.\d+\.\d+$/.test(revision) ? revision : null;
  }
  try {
    const value = JSON.parse(query.stdout);
    return value && /^\d+\.\d+\.\d+$/.test(value.version) && /^[0-9a-f]{40}$/.test(value.revision)
      ? { display: `${value.version}+${value.revision}`, probe: value.revision }
      : null;
  } catch {
    return null;
  }
}

function evidenceRecord(record, result, receiptDigest, bunRevision) {
  return {
    schema: "keld.compat.evidence/v1",
    artifact: {
      sha256: `sha256:${record.selected_artifact.sha256}`,
      platform: "windows",
      arch: "x86_64",
    },
    revisions: {
      keld: "de40149247fe9b410ba4954da167a445393f812c",
      bun: bunRevision,
      engine: `better-sqlite3-${record.version}`,
    },
    authority_profile: "legacy_sandbox_off",
    operation: {
      id: "native-addon.better-sqlite3.sql-callback-teardown",
      kind: "primary_workflow",
      oracle: {
        id: "sql-callback-result-negative-query-and-close",
        revision: "kel215-windows-v1",
      },
    },
    result,
    evidence_uri: `sha256:${receiptDigest}`,
  };
}

function execute(options = {}) {
  const root = options.root ?? here;
  const io = options.io ?? fs;
  const spawn = options.spawn ?? spawnSync;
  const runId = options.runId ?? freshRunId();
  const paths = outputPaths(root, runId);
  assertFresh(paths, io);

  const runtimeQueries = {
    bun: normalizeSpawn("bun", ["-e", "console.log(JSON.stringify({version:Bun.version,revision:Bun.revision}))"], {}, spawn),
    node: normalizeSpawn("node", ["--version"], {}, spawn),
  };
  const runs = MATRIX.map((entry) => normalizeSpawn(entry.runtime, ["probe.cjs", entry.alias], { cwd: root }, spawn));
  const receipt = {
    schema: "kel215.native-addon-receipt/v1",
    run_id: runId,
    fixture_sha256: fileHash(root, "probe.cjs", io),
    lock_sha256: fileHash(root, "bun.lock", io),
    package_sha256: fileHash(root, "package.json", io),
    runtime_queries: runtimeQueries,
    runs,
  };
  const rawJson = `${JSON.stringify(receipt, null, 2)}\n`;

  const bunRevision = runtimeRevision(runtimeQueries.bun, "bun");
  const nodeRevision = runtimeRevision(runtimeQueries.node, "node");
  const records = runs.map(parseJsonOutput);
  const valid = Boolean(bunRevision && nodeRevision && MATRIX.every((expected, index) => {
    const run = runs[index];
    const revision = expected.runtime === "bun" ? bunRevision.probe : nodeRevision;
    if (run.exit_code !== expected.expectedExit || run.signal || run.spawn_error || run.stderr !== "") return false;
    return expected.expectedExit === 0
      ? validatePositive(records[index], expected, revision)
      : validateExpectedFailure(records[index], expected, revision);
  }));

  let summaryJson;
  let evidence13Json;
  let evidence12Json;
  if (valid) {
    const digest = sha256(Buffer.from(rawJson));
    summaryJson = `${JSON.stringify({
      fixture: "kel215-better-sqlite3-differential",
      platform: "windows",
      arch: "x86_64",
      run_id: runId,
      receipt_sha256: digest,
      runs: records,
    }, null, 2)}\n`;
    evidence13Json = `${JSON.stringify(evidenceRecord(records[0], "pass", digest, bunRevision.display), null, 2)}\n`;
    evidence12Json = `${JSON.stringify(evidenceRecord(records[1], "fail", digest, bunRevision.display), null, 2)}\n`;
  }

  io.writeFileSync(paths.raw, rawJson, { flag: "wx" });
  if (valid) {
    io.writeFileSync(paths.summary, summaryJson, { flag: "wx" });
    io.writeFileSync(paths.evidence13, evidence13Json, { flag: "wx" });
    io.writeFileSync(paths.evidence12, evidence12Json, { flag: "wx" });
  }
  return { valid, runId, paths };
}

if (require.main === module) {
  if (process.platform !== "win32" || process.arch !== "x64") {
    throw new Error("KEL-215 receipt requires Windows x64");
  }
  try {
    const result = execute({ runId: process.argv[2] });
    console.log(JSON.stringify(result));
    if (!result.valid) process.exitCode = 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  MATRIX,
  assertFresh,
  execute,
  normalizeSpawn,
  outputPaths,
  runtimeRevision,
  validateExpectedFailure,
  validatePositive,
};
