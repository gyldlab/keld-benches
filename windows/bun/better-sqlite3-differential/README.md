# KEL-215 better-sqlite3 operation differential

This Windows-only fixture measures two pinned `better-sqlite3` releases under the
installed Node and Bun runtimes. It does not claim that a package name, import, source
inspection, or one artifact proves a different version, OS, architecture, ABI, runtime,
or operation.

The probe requires a real SQL create/insert/select operation, a registered synchronous
SQL callback, deterministic teardown, and a failing unknown-column query. It emits the
loaded package version, runtime revision, runtime Node-API value when exposed, native
candidate inventory, selected native binary digest, successfully loaded binary digest,
and each observable. The runner checks the 13.0.3 Node-API declaration against its
package/version expectation and independently queries each runtime's Node-API value. A
failed native load during `Database` construction retains the loader-selected binary
and failure details; it is not reported as a successfully loaded binary.

Run from this directory after installing the locked aliases. `run.cjs` retains each command, stdout, stderr and exit in a checksummed raw receipt; the older summary is superseded and is not reconstructed as raw evidence:

```powershell
bun install
node --test run.test.cjs
node run.cjs
```

Each invocation uses a fresh run id and refuses to reuse any output in that set before
launching a subprocess. An invalid matrix writes only its fresh raw diagnostic receipt;
it cannot mix new raw output with an older summary or evidence row. Generated
`node_modules` and uncommitted command output remain local evidence until a reviewed
immutable artifact record names their digests.
