# draw.io 31.7.0 CSSOM compatibility: **unscored, modified-app diagnostic**

This is a small **application-only diagnostic fixture**, not a new performance runner, product change or approved KELD-versus-Electron comparison. It reproduces the same change against a byte-pinned, externally supplied original draw.io 31.7.0 source tree. No whole app bundles, raw GUI recordings, system paths or machine-specific results are committed.

## Hypothesis and observed evidence

The original draw.io renderer's `mxSvgCanvas2D.setCssText` uses `element.setAttribute('style', generatedCSS)` on SVG `foreignObject` label wrappers. Under KELD's unchanged `original-editor-offline` H2 Content Security Policy (CSP), a macOS WKWebView offscreen diagnostic observed `style-src-attr` blocking the resulting 220-by-100 CSS geometry. Calling `element.style.cssText = generatedCSS` instead applied the same geometry in that fixture without changing H2. The test also observed that `<style>`, parsed inline attributes and inline scripts remained blocked. Those results are *observations on one local WebKit build*, not general browser or security guarantees.

A KELD native session with a **modified copy** of the original 31.7.0 app then opened the paired `.drawio` document (SHA-256 `a6dfa7788bcbe85bcd20080675da480c05d54d390993b7b48ae97d7081aa1a78`). The 220-by-100 box became visibly rendered at the toolbar's 100% zoom. Original KELD screenshots of the same input at 100% did not show the box. Native File > Exit, Host/Guardian/Bun termination and native test (1 pass, 0 failures) were separately witnessed. App name and singleton identity differed between the two candidate sessions, so this is **not a matched-profile causal A/B or production fix**.

## Generate once from pinned original sources

From this repository root, with an independently verified draw.io 31.7.0 source tree and its original KELD profile available **outside** this repository:

```sh
python3 -B macos/keld/drawio31-cssom-diagnostic/patch_drawio31.py \
  --webroot ../local-original-drawio31/drawio/src/main/webapp \
  --policy ../local-original-drawio31/keld.permissions.jsonc \
  --output ../new-private-cssom-diagnostic
node macos/keld/drawio31-cssom-diagnostic/test_cssom.cjs \
  ../new-private-cssom-diagnostic/js/app.min.js
node --check ../new-private-cssom-diagnostic/js/app.min.js
```

The input must match pinned SHA-256 hashes. Only one occurrence of the targeted function is allowed. Output must be a new directory. Two bytes-bound replacements are generated, one in readable `mxSvgCanvas2D.js` and one in the minified bundle. The output includes `readable-source.patch` and `receipt.json`. Expected bundled output SHA-256 is `744455ebd2c9f63db3fb9443201577f6465d99507cdcf8f61fe1a34222f5c13d`.

Offline tests need no installed draw.io or native GUI:

```sh
python3 -B macos/keld/drawio31-cssom-diagnostic/test_patch_drawio31.py
node macos/keld/drawio31-cssom-diagnostic/test_cssom.cjs
```

## Admission and security hold

- **Security:** `generatedCSS` may reflect untrusted graph style values (fonts, colors, backgrounds and borders). `style.cssText` can parse CSS the original CSP blocked as an inline attribute. Verify hostile values, escape/delimiter cases, `url()`, `@import`, unauthorized network/file requests, SVG `foreignObject`, nested HTML labels and runtime/IPC authority. Prove denial through native resource-policy receipts, not only DOM events. Do not relax `style-src` globally, inject scripts, or enable file grants. If generated wrapper strings cannot be constrained, use a narrowly validated property-level assignment rather than wholesale CSS parsing. This fixture **does not pass** those security gates.
- **Application:** This is an explicitly modified draw.io arm. A controlled *fresh-profile, identical identity, same-file, same-version* original-versus-patched A/B is still required. Rebuild all relevant bundles from readable app source if this compatibility patch is ever proposed for production; only `app.min.js` was exercised here. Future renderer forks and Windows/Linux need their own evidence.
- **Performance:** KEL-90's existing macOS benchmark owns scored measurements and the metric/result registry. Do not score this fixture, copy private measurements here, integrate Draft PR #63's 32.6.1 file checker with the 31.7.0 workflow, or infer a RAM/CPU win. Require independently correct native Open→Edit→Save→fresh Reopen→Quit, identical real workload and viewport, at least 30 balanced independent launches per arm, complete process attribution and failure controls, then benchmark-owner admission. Existing physical-footprint and CPU observations were per process, not a scientific full-app comparison.

The unmodified original corpus, H2 CSP, offline resources and Host remain unchanged by this generator. No merge or publication is implied by tests passing.
