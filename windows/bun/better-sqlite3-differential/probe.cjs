const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

function nativeArtifact(file, readFile = fs.readFileSync) {
  return {
    path: path.relative(process.cwd(), file).replaceAll("\\", "/"),
    sha256: crypto.createHash("sha256").update(readFile(file)).digest("hex"),
  };
}

function selectedNativeArtifact(packageRoot, version, options = {}) {
  const exists = options.existsSync ?? fs.existsSync;
  const readFile = options.readFileSync ?? fs.readFileSync;
  const resolveBindings = options.resolveBindings ?? ((root) => {
    const bindingsModule = require.resolve("bindings", { paths: [root] });
    return require(bindingsModule)({
      bindings: "better_sqlite3.node",
      module_root: root,
      path: true,
    });
  });
  const prebuild = path.join(packageRoot, "prebuilds", "win32-x64.node");
  const build = path.join(packageRoot, "build", "Release", "better_sqlite3.node");
  const inventory = [prebuild, build].filter(exists);
  if (inventory.length === 0) throw new Error("no Windows native artifact candidate exists");

  const selected = version === "12.11.1" ? resolveBindings(packageRoot) : prebuild;
  if (!inventory.includes(selected)) {
    throw new Error(`loader selected an unrecorded native artifact: ${selected}`);
  }
  return {
    selected: nativeArtifact(selected, readFile),
    candidates: inventory.map((candidate) => nativeArtifact(candidate, readFile)),
  };
}

function loadedNativeArtifact(packageRoot) {
  const loaded = Object.keys(require.cache).find((candidate) =>
    candidate.startsWith(packageRoot) && candidate.endsWith(".node")
  );
  if (!loaded) throw new Error("no loaded native artifact was present in require.cache");
  return nativeArtifact(loaded);
}

function main(packageName) {
  if (!packageName) throw new Error("usage: probe.cjs <package alias>");
  const packageJson = require(`${packageName}/package.json`);
  const packageRoot = path.dirname(require.resolve(`${packageName}/package.json`));
  const native = selectedNativeArtifact(packageRoot, packageJson.version);
  const addonAbi = packageJson.version === "13.0.3" ? "node-api-10 (binding.gyp)" : undefined;
  const identity = {
    package: packageJson.name,
    version: packageJson.version,
    runtime: process.versions.bun ? "bun" : "node",
    runtime_revision: process.versions.bun ? Bun.revision : process.version,
    runtime_node_api: process.versions.napi || null,
    ...(addonAbi ? { addon_abi: addonAbi } : {}),
    selected_artifact: native.selected,
    native_candidates: native.candidates,
  };

  const Database = require(packageName);
  let db;
  try {
    db = new Database(":memory:");
  } catch (error) {
    console.log(JSON.stringify({
      ...identity,
      attempted_load: "failed",
      error_code: error.code || error.name,
      error: error.message,
    }));
    process.exitCode = 1;
    return;
  }

  let result;
  let negative;
  try {
    db.exec("CREATE TABLE items (value INTEGER); INSERT INTO items VALUES (41);");
    db.function("plus_one", (value) => value + 1);
    result = db.prepare("SELECT plus_one(value) AS value FROM items").get().value;
    try {
      db.prepare("SELECT absent_column FROM items").get();
    } catch (error) {
      if (error.code === "SQLITE_ERROR" && /absent_column/i.test(error.message)) negative = error.code;
      else throw error;
    }
  } finally {
    db.close();
  }

  let teardown;
  try {
    db.prepare("SELECT 1").get();
  } catch (error) {
    if (error instanceof TypeError && /not open/i.test(error.message)) teardown = "closed";
    else throw error;
  }
  if (result !== 42 || negative !== "SQLITE_ERROR" || teardown !== "closed") {
    throw new Error(`operation contract failed: result=${result}; negative=${negative}; teardown=${teardown}`);
  }
  console.log(JSON.stringify({
    ...identity,
    artifact: loadedNativeArtifact(packageRoot),
    query_callback_result: result,
    negative_control: negative,
    teardown: "closed",
  }));
}

if (require.main === module) main(process.argv[2]);

module.exports = { main, selectedNativeArtifact };
