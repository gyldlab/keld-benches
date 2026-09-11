const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const packageName = process.argv[2];
if (!packageName) throw new Error("usage: probe.cjs <package alias>");

function loadedNativeArtifact(packageRoot) {
  const loaded = Object.keys(require.cache).find((candidate) =>
    candidate.startsWith(packageRoot) && candidate.endsWith(".node")
  );
  if (!loaded) throw new Error("no loaded native artifact was present in require.cache");
  return { path: path.relative(process.cwd(), loaded).replaceAll("\\", "/"), sha256: crypto.createHash("sha256").update(fs.readFileSync(loaded)).digest("hex") };
}

const packageJson = require(`${packageName}/package.json`);
const packageRoot = path.dirname(require.resolve(`${packageName}/package.json`));
const Database = require(packageName);
const db = new Database(":memory:");
let result;
let negative;
try {
  db.exec("CREATE TABLE items (value INTEGER); INSERT INTO items VALUES (41);");
  db.function("plus_one", (value) => value + 1);
  result = db.prepare("SELECT plus_one(value) AS value FROM items").get().value;
  try { db.prepare("SELECT absent_column FROM items").get(); } catch (error) { negative = error.code || error.name; }
} finally {
  db.close();
}
if (result !== 42 || !negative) throw new Error(`operation contract failed: result=${result}; negative=${negative}`);
console.log(JSON.stringify({
  package: packageJson.name,
  version: packageJson.version,
  runtime: process.versions.bun ? "bun" : "node",
  runtime_revision: process.versions.bun ? Bun.revision : process.version,
  node_api: process.versions.napi || null,
  artifact: loadedNativeArtifact(packageRoot),
  query_callback_result: result,
  negative_control: negative,
  teardown: "closed"
}));
