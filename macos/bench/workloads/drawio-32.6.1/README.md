# draw.io 32.6.1 saved-file oracle (unscored)

This is a **file-state correctness fixture**, not an application benchmark runner. It implements one bounded part of the real-application workload in [Draft PR #62](https://github.com/gyldlab/keld-benches/pull/62). It does not create or modify a macOS KEL-64 runner, a KEL-90 score/metric, the product-corpus acceptance owner, or KELD production privileges.

## Pinned synthetic workload

- input.drawio contains one page, two labelled nodes and a connecting edge.
- On **each** Electron and KELD arm, open the exact committed input, change the **Beta** node label to **Beta (edited)**, save and reopen.
- expected.drawio is a reference for **only** that edit.
- manifest.json pins the original and expected file bytes with SHA-256 hashes and records the exact required edit.

Do not substitute a previously generated file for an actual application output and call it a GUI pass. A controller must independently observe each real app run, bind its output to the launched artifact and session, and place the saved output in a private evidence directory **outside** the repository.

For each arm's saved output, run from the repository root:

    python3 macos/bench/workloads/drawio-32.6.1/check_saved.py --saved /private/evidence/arm-output.drawio

Run portable tests:

    python3 macos/bench/workloads/drawio-32.6.1/test_check_saved.py

The checker supports an uncompressed mxfile or the usual raw-DEFLATE, URI-encoded draw.io mxfile. It compares page identity and ordering, graph settings (except editor scroll dx/dy), cell identity and z-order, labels, style, geometry, edge references and other nested XML. Non-graph editor metadata such as modified, agent, version, host is excluded.

Invalid XML, DTD/entities, corrupt compression, oversized files, unsupported cell wrappers, duplicate IDs, dangling references, unexpected content, missing/wrong edits and hash mismatches **fail closed**. Unrecognized draw.io encodings or constructs are unsupported until a new valid-path test and negative control justify them. The checker does **not** attempt semantic equivalence for freshly generated IDs or different graph constructions.

The stdout JSON is a **file-only receipt**, not a schema/result.vN benchmark document. It cannot establish that a GUI opened, edited, saved or reopened a file; that Cancel/Discard/Quit worked; that all processes were attributed or cleaned up; or that RAM, CPU, startup, scanout/paint or release-grade comparisons passed. Copying expected.drawio to the supplied --saved path can pass this checker. The app-run controller, not this file parser, must bind the output to the actual application session.

Do not commit run outputs into this directory or under */bench/results/, and do not publish a performance claim based on this receipt. Native test qualifications, artifact provenance, matching zoom/render configuration, process ownership and 30 independently qualified paired launches remain separate gates.
