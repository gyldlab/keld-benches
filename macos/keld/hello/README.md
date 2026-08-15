# Keld macOS hello benchmark adapter

This fixture keeps benchmark-only URL plumbing out of the Keld product. The
build script creates a fresh detached checkout at an exact Keld commit, applies
the committed adapter patch, builds `keld-host`, wraps the executable in a real
`.app`, embeds source/patch/build provenance in `Info.plist`, and ad-hoc signs
the result. Both the source checkout and recipe-object snapshot are fetched
from literal canonical HTTPS URLs. It refuses an abbreviated source commit, a
source or recipe commit that is not currently advertised as an exact canonical
branch head, a non-canonical origin, external local Git-config includes, a dirty
adapter-recipe checkout, or an existing output path. Toolchain probes and the
Cargo build run with a minimal explicit environment and an isolated temporary
`CARGO_HOME`. Git provenance commands also run in a scrubbed environment; live
branch-head queries use literal public HTTPS URLs outside either checkout.
Before building, the script compares the worktree bytes of its canonical build
script, plist template, and adapter patch directly against freshly fetched Git
blobs without applying content filters, then uses verified blob snapshots for
the patch, plist, and embedded recipe hashes.

The output path must not exist. Final installation uses
`renameatx_np(RENAME_EXCL)`, so a destination created during the build cannot be
overwritten or mistaken for a container directory. Staging and output must be
on the same filesystem; set `TMPDIR` on the output filesystem when needed.

```bash
source_git_sha=$(/usr/bin/env -i \
  HOME=/var/empty \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_NO_REPLACE_OBJECTS=1 \
  GIT_OPTIONAL_LOCKS=0 \
  GIT_TERMINAL_PROMPT=0 \
  /usr/bin/git -C /absolute/path/to/keld rev-parse HEAD)

./macos/keld/hello/build.sh \
  /absolute/path/to/keld \
  "$source_git_sha" \
  "/absolute/output/Keld Hello.app"
```

The adapter only changes the benchmark checkout: when `KELD_BENCH_URL` is
present, Keld's existing `--hello` window uses that URL as its initial
navigation. Without the environment variable, the checked-in inline hello is
unchanged. The harness passes the unique run token in the URL and environment;
Keld uses the same constant `Hello` native title as the Tauri arm.
