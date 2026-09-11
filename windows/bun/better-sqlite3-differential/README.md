# KEL-215 better-sqlite3 operation differential

This Windows-only fixture measures two pinned `better-sqlite3` releases under the
installed Node and Bun runtimes. It does not claim that a package name, import, source
inspection, or one artifact proves a different version, OS, architecture, ABI, runtime,
or operation.

The probe requires a real SQL create/insert/select operation, a registered synchronous
SQL callback, deterministic teardown, and a failing unknown-column query. It emits the
loaded package version, runtime revision, Node-API value when exposed, native binary
digest, and each observable. A failed install/import must be retained as a failure rather
than replaced with the other package.

Run from this directory after installing the locked aliases. `run.cjs` retains each command, stdout, stderr and exit in a checksummed raw receipt; the older summary is superseded and is not reconstructed as raw evidence:

```powershell
bun install
node run.cjs
```

Generated `node_modules`, lockfiles, and raw command output are local evidence until a
reviewed immutable artifact record names their digests.
