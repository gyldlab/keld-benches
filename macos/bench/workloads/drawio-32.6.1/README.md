# draw.io 32.6.1 saved-file oracle (unscored)

This is a **file-state correctness fixture**, not an application benchmark runner. It implements one bounded part of the real-application workload in [Draft PR #62](https://github.com/gyldlab/keld-benches/pull/62). It does not create or modify a macOS KEL-64 runner, a KEL-90 score/metric, the product-corpus acceptance owner, or KELD production privileges.

**Integration is on hold.** The [owner decision](https://github.com/gyldlab/keld-benches/pull/63#issuecomment-6613613696) keeps this helper out of GUI acceptance and performance publication. The approved original product corpus pins 31.7.0, not this 32.6.1 synthetic example. A file-parser fix does not change that decision. First use the existing approved app workflow with its correct source version and unique per-attempt content. Integrate an optional helper only if actual outputs demonstrate a remaining integrity gap and the existing owners admit it. Keep this PR Draft and unmerged.

## Pinned synthetic workload

- input.drawio contains one page, two labelled nodes and a connecting edge.
- The illustrative edit changes the **Beta** node label to **Beta (edited)**. This fixed example is not an admitted Electron or KELD app-run workflow.
- expected.drawio is a reference for **only** that edit.
- manifest.json pins the original and expected file bytes with SHA-256 hashes and records the exact required edit.

Do not substitute a previously generated file for an actual application output and call it a GUI pass. A controller must independently observe each real app run, bind its output to the launched artifact and session, and place the saved output in a private evidence directory **outside** the repository.

For a file-only check, set `EVIDENCE_DIR` to the private evidence directory outside this repository. Run from the repository root:

    python3 macos/bench/workloads/drawio-32.6.1/check_saved.py --saved "$EVIDENCE_DIR/arm-output.drawio"

Run portable tests:

    python3 macos/bench/workloads/drawio-32.6.1/test_check_saved.py

The checker supports an uncompressed mxfile or the usual raw-DEFLATE, URI-encoded draw.io mxfile. It compares file variables and other file attributes, all page attributes and ordering, graph settings (except editor scroll dx/dy), graph-root attributes, cell identity and z-order, labels, style, geometry, edge references and other nested XML. Only these mxfile editor/representation attributes are excluded: host, modified, agent, etag, version, type, userAgent, editor, compressed and pages. Actual diagram nodes and content determine page count and encoding. Unknown attributes are not silently discarded.

Compressed content requires valid percent escapes and UTF-8 before XML parsing. DTDs are refused by the XML parser, including in UTF-16 input and compressed pages. Each file is limited to 4 MiB. All compressed pages together may expand to at most 16 MiB before URI decoding. The outer document and decoded pages share a 50,000-element limit. Each parsed XML tree has a depth limit of 64. These limits apply before recursive graph comparison; an over-limit file returns a named refusal instead of an interpreter traceback.

The interpretation follows the pinned draw.io 32.6.1 sources: [Graph.decompress](https://github.com/jgraph/drawio/blob/84487b4891cbc0f32d7e30f34cf878c87cb1f414/src/main/webapp/js/grapheditor/Graph.js#L3527-L3540), [Editor.parseDiagramNode](https://github.com/jgraph/drawio/blob/84487b4891cbc0f32d7e30f34cf878c87cb1f414/src/main/webapp/js/diagramly/Editor.js#L2624-L2655), and [EditorUi metadata handling](https://github.com/jgraph/drawio/blob/84487b4891cbc0f32d7e30f34cf878c87cb1f414/src/main/webapp/js/diagramly/EditorUi.js#L2701-L2738). These source checks do not establish native output compatibility.

Invalid XML, DTD/entities, corrupt compression, oversized files, unsupported cell wrappers, duplicate IDs, dangling references, unexpected content, missing/wrong edits and hash mismatches **fail closed**. Unrecognized draw.io encodings or constructs are unsupported until a new valid-path test and negative control justify them. The checker does **not** attempt semantic equivalence for freshly generated IDs or different graph constructions.

The stdout JSON is a **file-only receipt**, not a schema/result.vN benchmark document. It cannot establish that a GUI opened, edited, saved or reopened a file; that Cancel/Discard/Quit worked; that all processes were attributed or cleaned up; or that RAM, CPU, startup, scanout/paint or release-grade comparisons passed. Copying expected.drawio to the supplied --saved path can pass this checker. The app-run controller, not this file parser, must bind the output to the actual application session.

Do not commit run outputs into this directory or under */bench/results/, and do not publish a performance claim based on this receipt. Native test qualifications, artifact provenance, matching zoom/render configuration, process ownership and 30 independently qualified paired launches remain separate gates.
