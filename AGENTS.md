# AGENTS.md — benchmark evidence floor

This file owns agent process, not benchmark meaning. `HARNESS-CONTRACT.md` owns
fixture layout, comparison, result immutability, and publication. The metric
registry, version-selected result schema, and canonical payload own their named
machine-readable contracts. Change an owner and its consumers together.

## Atomic performance proof

Before a design, harness, or result change, separate these atoms. A pass in one
MUST NOT prove another; expose coupling as an edge. Synthesize only after each
decision-bearing atom passes, is explicitly unknown, or is a named blocker.

| Atom | Owner and boundary | Input → output | Failure and direct observable |
|---|---|---|---|
| Census | OS runner; process-tree boundary | launch → generation-bound members | missed/foreign member; identity/lifecycle census |
| Work | fixture; payload-to-completion boundary | metric + canonical payload → same-class work | scope drift; payload hash + metric completion |
| Queue/copy | OS hook; transport/render boundary | operation → attributed queues/copies | hidden buffer/copy; counter/trace or unknown |
| Clock/oracle | OS runner; spawn-to-event interval | external monotonic start + nonce signal → duration | stale, duplicate, wrong-phase, missing signal, or timeout; rejection control |
| Statistic | OS runner; sample-to-verdict boundary | paired samples + registry → summary/CI/verdict | bad pooling/estimator; deterministic reference |
| Artifact provenance | build recipe; source-to-artifact boundary | immutable inputs → hashed artifact | dirty/mismatched input; verification + tamper control |

## Change discipline

- Before editing, identify the governing `HARNESS-CONTRACT.md` section and
  existing owner. Extend that owner; if the contract must change, update its
  implementation, consumer, and test in the same change.
- A dependency, abstraction, fixture, or CI lane MUST serve a named unmet
  contract with a direct falsifier. Prefer the smallest extension of the owning
  surface; speculative completeness and duplicated convenience helpers do not
  justify new machinery.
- Unavailable OS evidence is **unverified**. CI, another OS, simulation, or
  inference MUST NOT be reported as that OS passing.
- For behavior changes, run the checks and negative controls required by
  `HARNESS-CONTRACT.md` §2 and record the fault each control rejects. One
  atom's passing test MUST NOT substitute for another atom's evidence.

## Routed CI and publication

- `ci/plan.py` owns path classification and immutable-evidence rejection;
  `ci/required.py` owns aggregate admission; the workflow only executes those
  decisions. MUST NOT copy route tables or result-state truth tables elsewhere.
- Agents MUST execute the planner for applicability and MUST NOT infer routes
  from filenames or this prose.
- Run `ci/check_instructions.py test`, `ci/check_instructions.py check`,
  `ci/test_plan.py`, and `ci/test_required.py` after changing instructions or
  CI. Unknown executable inputs must fail safe through the planner owner.
- Hosted CI MUST NOT generate, overwrite, re-emit, upload, or publish benchmark
  results. Real measurement remains an OS-local `HARNESS-CONTRACT.md` procedure.
