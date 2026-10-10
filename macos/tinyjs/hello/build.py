#!/usr/bin/env python3
"""Package a pinned TinyJSApp release. This is a build recipe, not a metric runner."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CANONICAL = ROOT / "schema/canonical-payload.v1.html"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def reserve_output(path: Path, source: Path = ROOT) -> Path:
    if path.is_symlink():
        raise ValueError("build output must not be a symlink")
    path = path.resolve()
    source = source.resolve()
    if path == source or source in path.parents:
        raise ValueError("build output must be outside the benchmark source tree")
    # Never delete/replace a caller's existing directory, including a symlink.
    path.mkdir(mode=0o700, parents=True, exist_ok=False)
    return path


def extract_sdk(archive: Path, dest: Path, pin: dict) -> Path:
    # Verify before parsing the archive, let alone executing the downloaded CLI.
    if archive.stat().st_size != pin["bytes"] or sha256(archive) != pin["sha256"]:
        raise ValueError("SDK archive size or SHA-256 differs from the committed pin")
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        seen = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or not path.parts
                    or path.parts[0] != "tinyjs"
                    or not (member.isdir() or member.isfile()) or path in seen):
                raise ValueError("unsafe or duplicate SDK archive member: " + member.name)
            seen.add(path)
        # Extract only regular files/directories; refuse links and special files.
        dest.mkdir(parents=True, exist_ok=False)
        for member in members:
            target = dest / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(member) as src, target.open("xb") as out:
                shutil.copyfileobj(src, out)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    return dest / "tinyjs"


def stage_project(out: Path) -> Path:
    project = out / "project"
    (project / "src/frontend").mkdir(parents=True, exist_ok=False)
    shutil.copyfile(HERE / "tinyjs.json", project / "tinyjs.json")
    shutil.copyfile(HERE / "src/main.js", project / "src/main.js")
    # One owner for workload bytes, no forked HTML copy or timing instrumentation.
    shutil.copyfile(CANONICAL, project / "src/frontend/index.html")
    return project


def verify_payload(app: Path) -> None:
    actual = app / "Contents/Resources/app/frontend/index.html"
    if actual.read_bytes() != CANONICAL.read_bytes():
        raise ValueError("packaged renderer differs from the canonical payload")
    backend = app / "Contents/Resources/app/src/main.js"
    if backend.read_bytes() != (HERE / "src/main.js").read_bytes():
        raise ValueError("packaged backend differs from the source fixture")


def build(out: Path, archive: Path | None = None) -> Path:
    arch = platform.machine()
    if platform.system() != "Darwin" or arch not in {"arm64", "x86_64"}:
        raise ValueError("requires native macOS arm64 or x86_64; other OSes are unqualified")
    subprocess.run(["/usr/bin/xcode-select", "-p"], check=True, capture_output=True)
    inputs = [HERE / "build.py", HERE / "upstream.json", HERE / "tinyjs.json",
              HERE / "src/main.js", CANONICAL]
    before = {p.relative_to(ROOT).as_posix(): sha256(p) for p in inputs}
    bench_sha = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                                        text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"]))
    upstream = json.loads((HERE / "upstream.json").read_text())
    pin = upstream["assets"][arch]
    out = reserve_output(out)
    if archive is None:
        archive = out / pin["name"]
        url = ("https://github.com/" + upstream["repository"] + "/releases/download/"
               + upstream["version"] + "/" + pin["name"])
        subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent",
                        "--show-error", "--proto", "=https", "--proto-redir", "=https",
                        url, "--output", str(archive)], check=True, timeout=180)
    sdk = extract_sdk(archive.resolve(), out / "sdk", pin)
    if (sdk / "VERSION").read_text().strip() != upstream["version"]:
        raise ValueError("SDK version differs from pin")
    # No global install, inherited feature/signing knobs or user cache mutation.
    for folder in ("home", "tmp"):
        (out / folder).mkdir()
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(out / "home"),
           "TMPDIR": str(out / "tmp") + "/", "LC_ALL": "C"}
    runtime = subprocess.check_output([str(sdk / "bin/tjs"), "--version"],
                                      env=env, text=True).strip()
    if runtime != upstream["runtime_version"]:
        raise ValueError("runtime version differs from pin")
    project = stage_project(out)
    subprocess.run([str(sdk / "bin/tjs"), "run", str(sdk / "cli.js"),
                    "build", "--arch", arch], cwd=project, env=env, check=True,
                   timeout=600)
    app = project / "dist/TinyJS Hello.app"
    verify_payload(app)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)],
                   check=True, env=env)
    for name in ("tinyjs-hello", "tjs"):
        binary = app / "Contents/MacOS" / name
        slices = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)],
                                         env=env, text=True).split()
        if slices != [arch]:
            raise ValueError("expected one native architecture in " + name)
    if before != {p.relative_to(ROOT).as_posix(): sha256(p) for p in inputs}:
        raise ValueError("source inputs changed during the build")
    files = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise ValueError("unexpected symlink in built app")
        if path.is_file():
            files.append({"path": path.relative_to(app).as_posix(),
                          "bytes": path.stat().st_size, "sha256": sha256(path)})
    manifest = {
        "kind": "tinyjs-build-provenance/v1", "upstream": upstream,
        "architecture": arch, "packaging": "upstream-release-cli-native-arch-app",
        "signing": "ad-hoc; not notarized", "engine_class": "system-wkwebview",
        "payload_sha256": sha256(CANONICAL),
        "source_inputs": before, "bench_sha": bench_sha, "source_dirty": dirty,
        "app_files": files,
        "measurement_status": "unmeasured; macOS runner admission still required",
    }
    (out / "build-provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new directory outside this repository")
    parser.add_argument("--sdk-archive", type=Path, help="optional archive; same pin is enforced")
    args = parser.parse_args()
    try:
        print(build(args.output, args.sdk_archive))
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(2, "build refused: " + str(error) + "\n")
