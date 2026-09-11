const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const packageName = process.argv[2];
if (!packageName) throw new Error("usage: probe.cjs <package alias>");

function selectedNativeArtifact(packageRoot) {
  const candidates = [path.join(packageRoot, "prebuilds", "win32-x64.node"), path.join(packageRoot, "build", "Release", "better_sqlite3.node")];
  const selected = candidates.find(fs.existsSync);
  if (!selected) throw new Error("no selected Windows native artifact exists");
  return { path: path.relative(process.cwd(), selected).replaceAll("\\", "/"), sha256: crypto.createHash("sha256").update(fs.readFileSync(selected)).digest("hex") };
}

function loadedNativeArtifact(packageRoot) {
  const loaded = Object.keys(require.cache).find((candidate) =>
    candidate.startsWith(packageRoot) && candidate.endsWith(".node")
  );
  if (!loaded) throw new Error("no loaded native artifact was present in require.cache");
  return { path: path.relative(process.cwd(), loaded).replaceAll("\\", "/"), sha256: crypto.createHash("sha256").update(fs.readFileSync(loaded)).digest("hex") };
}

const packageJson = require(`${packageName}/package.json`);
const packageRoot = path.dirname(require.resolve(`${packageName}/package.json`));
const selectedArtifact = selectedNativeArtifact(packageRoot);
const Database = require(packageName);
let db;
try { db = new Database(":memory:"); } catch (error) {
  console.log(JSON.stringify({ package: packageJson.name, version: packageJson.version, runtime: process.versions.bun ? "bun" : "node", runtime_revision: process.versions.bun ? Bun.revision : process.version, runtime_node_api: process.versions.napi || null, selected_artifact: selectedArtifact, attempted_load: "failed", error_code: error.code || error.name, error: error.message }));
  process.exitCode = 1;
  return;
}
let result;
let negative;
try {
  db.exec("CREATE TABLE items (value INTEGER); INSERT INTO items VALUES (41);");
  db.function("plus_one", (value) => value + 1);
  result = db.prepare("SELECT plus_one(value) AS value FROM items").get().value;
  try { db.prepare("SELECT absent_column FROM items").get(); } catch (error) {
    if (error.code === "SQLITE_ERROR" && /absent_column/i.test(error.message)) negative = error.code;
    else throw error;
  }
} finally {
  db.close();
}
let teardown;
try { db.prepare("SELECT 1").get(); } catch (error) {
  if (error instanceof TypeError && /not open/i.test(error.message)) teardown = "closed";
  else throw error;
}
if (result !== 42 || negative !== "SQLITE_ERROR" || teardown !== "closed") throw new Error(`operation contract failed: result=${result}; negative=${negative}; teardown=${teardown}`);
console.log(JSON.stringify({
  package: packageJson.name,
  version: packageJson.version,
  runtime: process.versions.bun ? "bun" : "node",
  runtime_revision: process.versions.bun ? Bun.revision : process.version,
  runtime_node_api: process.versions.napi || null,
  addon_abi: packageJson.version === "13.0.3" ? "node-api-10 (binding.gyp)" : "v8-node-abi (source audit)",
  selected_artifact: selectedArtifact,
  artifact: loadedNativeArtifact(packageRoot),
  query_callback_result: result,
  negative_control: negative,
  teardown: "closed"
}));
