const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const { execute, outputPaths, validatePositive } = require("./run.cjs");
const { selectedNativeArtifact } = require("./probe.cjs");

const root = __dirname;
const artifact = {
  path: "node_modules/better-sqlite3-13/prebuilds/win32-x64.node",
  sha256: "e21e5efd71fba66578e95b62554d9028064a80dafd7221bf8a8ef155de8d240a",
};

function positive(overrides = {}) {
  return {
    package: "better-sqlite3",
    version: "13.0.3",
    runtime: "bun",
    runtime_revision: "744846f844374847c902b5e7fd59b4342a51ef99",
    runtime_node_api: "10",
    addon_abi: "node-api-10 (binding.gyp)",
    selected_artifact: artifact,
    native_candidates: [artifact],
    artifact,
    query_callback_result: 42,
    negative_control: "SQLITE_ERROR",
    teardown: "closed",
    ...overrides,
  };
}

function successfulRows() {
  const bun12Artifact = {
    path: "node_modules/better-sqlite3-12/build/Release/better_sqlite3.node",
    sha256: "707a4b480026ccd1fb8e308d43c7248e779d35eeefa09559ec9bb521bb97bb3b",
  };
  return [
    { status: 0, stdout: `${JSON.stringify(positive())}\n`, stderr: "" },
    { status: 1, stdout: `${JSON.stringify({ package: "better-sqlite3", version: "12.11.1", runtime: "bun", runtime_revision: "744846f844374847c902b5e7fd59b4342a51ef99", runtime_node_api: "10", selected_artifact: bun12Artifact, native_candidates: [bun12Artifact], attempted_load: "failed", error_code: "ERR_DLOPEN_FAILED", error: "unsupported" })}\n`, stderr: "" },
    { status: 0, stdout: `${JSON.stringify(positive({ runtime: "node", runtime_revision: "v25.2.1" }))}\n`, stderr: "" },
    { status: 0, stdout: `${JSON.stringify(positive({ version: "12.11.1", runtime: "node", runtime_revision: "v25.2.1", addon_abi: undefined, selected_artifact: bun12Artifact, native_candidates: [bun12Artifact], artifact: bun12Artifact }))}\n`, stderr: "" },
  ];
}

function fakeIo(existing = new Set()) {
  const writes = new Map();
  return {
    writes,
    existsSync(file) { return existing.has(file) || writes.has(file); },
    readFileSync(file) { return fs.readFileSync(file); },
    writeFileSync(file, value, options) {
      assert.equal(options.flag, "wx");
      assert.equal(this.existsSync(file), false, `overwrite attempted: ${file}`);
      writes.set(file, value);
    },
  };
}

function spawnSequence(probes = successfulRows()) {
  const results = [
    { status: 0, stdout: '{"version":"1.4.2","revision":"744846f844374847c902b5e7fd59b4342a51ef99","napi":"10"}\n', stderr: "" },
    { status: 0, stdout: '{"version":"v25.2.1","napi":"10"}\n', stderr: "" },
    ...probes,
  ];
  let calls = 0;
  return {
    spawn() { calls += 1; return results.shift(); },
    calls() { return calls; },
  };
}

test("positive rows reject wrong identity and missing operation fields", () => {
  const expected = { runtime: "bun", version: "13.0.3" };
  expected.addonAbi = "node-api-10 (binding.gyp)";
  const runtime = { probe: "744846f844374847c902b5e7fd59b4342a51ef99", napi: "10" };
  for (const mutation of [
    { package: "other" },
    { version: "12.11.1" },
    { runtime: "node" },
    { runtime_revision: "WRONG" },
    { runtime_node_api: "WRONG" },
    { addon_abi: "WRONG" },
    { query_callback_result: undefined },
    { negative_control: undefined },
    { teardown: undefined },
    { artifact: undefined },
    { artifact: { ...artifact, sha256: "a".repeat(64) } },
  ]) {
    assert.equal(validatePositive(positive(mutation), expected, runtime), false, JSON.stringify(mutation));
  }
});

test("12.11.1 uses its bindings loader result when both candidate files exist", () => {
  const packageRoot = path.join(root, "node_modules", "better-sqlite3-12");
  const build = path.join(packageRoot, "build", "Release", "better_sqlite3.node");
  const selected = selectedNativeArtifact(packageRoot, "12.11.1", {
    existsSync: () => true,
    readFileSync: (file) => Buffer.from(file),
    resolveBindings: () => build,
  });
  assert.equal(selected.selected.path, "node_modules/better-sqlite3-12/build/Release/better_sqlite3.node");
  assert.equal(selected.candidates.length, 2);
});

test("hostile run ids fail before any process launch or write", () => {
  for (const runId of ["../../escape", "..\\..\\escape", "nested/name", "nested\\name", "", "x".repeat(129)]) {
    const io = fakeIo();
    const sequence = spawnSequence();
    assert.throws(() => execute({ root, runId, io, spawn: sequence.spawn }), /run id must be/);
    assert.equal(sequence.calls(), 0, runId);
    assert.equal(io.writes.size, 0, runId);
  }
});

test("an existing output rejects before any process launch or write", () => {
  const runId = "already-used";
  const paths = outputPaths(root, runId);
  const io = fakeIo(new Set([paths.summary]));
  const sequence = spawnSequence();
  assert.throws(() => execute({ root, runId, io, spawn: sequence.spawn }), /refusing to reuse output set/);
  assert.equal(sequence.calls(), 0);
  assert.equal(io.writes.size, 0);
});

test("a malformed positive payload retains only the fresh raw diagnostics", () => {
  const probes = successfulRows();
  probes[0] = { status: 0, stdout: `${JSON.stringify(positive({ runtime_revision: "WRONG", query_callback_result: undefined }))}\n`, stderr: "" };
  const sequence = spawnSequence(probes);
  const io = fakeIo();
  const result = execute({ root, runId: "malformed", io, spawn: sequence.spawn });
  assert.equal(result.valid, false);
  assert.deepEqual([...io.writes.keys()], [result.paths.raw]);
});

test("a runtime query launch failure is normalized and retains raw diagnostics", () => {
  const sequence = spawnSequence();
  let call = 0;
  const spawn = () => {
    call += 1;
    if (call === 1) return { status: null, signal: null, stdout: undefined, stderr: undefined, error: Object.assign(new Error("missing bun"), { code: "ENOENT" }) };
    return sequence.spawn();
  };
  const io = fakeIo();
  const result = execute({ root, runId: "missing-runtime", io, spawn });
  assert.equal(result.valid, false);
  assert.deepEqual([...io.writes.keys()], [result.paths.raw]);
  const receipt = JSON.parse(io.writes.get(result.paths.raw));
  assert.deepEqual(receipt.runtime_queries.bun.spawn_error, { code: "ENOENT", message: "missing bun" });
  assert.equal(receipt.runtime_queries.bun.exit_code, null);
  assert.equal(receipt.runtime_queries.bun.signal, null);
  assert.equal(receipt.runtime_queries.bun.stdout, "");
  assert.equal(receipt.runtime_queries.bun.stderr, "");
});

test("a probe launch failure retains status, signal, error, stdout, and stderr", () => {
  const probes = successfulRows();
  probes[2] = { status: null, signal: "SIGTERM", stdout: "partial", stderr: "stopped", error: Object.assign(new Error("terminated"), { code: "ECHILD" }) };
  const sequence = spawnSequence(probes);
  const io = fakeIo();
  const result = execute({ root, runId: "probe-launch-failure", io, spawn: sequence.spawn });
  assert.equal(result.valid, false);
  assert.deepEqual([...io.writes.keys()], [result.paths.raw]);
  const failed = JSON.parse(io.writes.get(result.paths.raw)).runs[2];
  assert.deepEqual(failed, {
    command: "node probe.cjs better-sqlite3-13",
    exit_code: null,
    signal: "SIGTERM",
    spawn_error: { code: "ECHILD", message: "terminated" },
    stdout: "partial",
    stderr: "stopped",
  });
});

test("a valid matrix serializes one coherent fresh output set", () => {
  const sequence = spawnSequence();
  const io = fakeIo();
  const result = execute({ root, runId: "valid", io, spawn: sequence.spawn });
  assert.equal(result.valid, true);
  assert.deepEqual(new Set(io.writes.keys()), new Set(Object.values(result.paths)));
  const rawDigest = crypto.createHash("sha256").update(io.writes.get(result.paths.raw)).digest("hex");
  assert.equal(JSON.parse(io.writes.get(result.paths.summary)).receipt_sha256, rawDigest);
  assert.equal(JSON.parse(io.writes.get(result.paths.evidence13)).evidence_uri, `sha256:${rawDigest}`);
  assert.equal(JSON.parse(io.writes.get(result.paths.evidence12)).evidence_uri, `sha256:${rawDigest}`);
});
