---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work. Anything actively being built gets a plan in
`../.agents/plans/active/` and a link from here.

## Open

- [ ] **Delphi parity is dated, not defended.** Measured 2026-07-22 (`143/21/4` corpus,
      `31/0` local, clean build). No licence available here grants `dcc32` — Starter never
      had it, and trials exclude the command-line compilers by design
      ([Embarcadero](https://support.embarcadero.com/article/44692)) — so the Delphi run is
      a manual rebuild of `tests/corpus_runner.dpr` and `tests/local_tests.dpr`, and CI
      cannot gate it. Re-run after any engine change; Architect trial expires ~2026-08-21.
      **Decide:** buy Professional+ and gate it, or keep the dated manual check.

      Partly mitigated: `build.sh` now also builds the local suite with `-Co -Cr`, which
      reproduces Delphi's Debug overflow/range checks under FPC — verified to catch the
      exact `EIntOverflow` that only Delphi had found. That closes one bug class, not the
      compiler difference itself.

- [ ] **Ungated surfaces: `#include` is the one left.** `tests/local_tests.dpr` now covers
      line terminators, the nil-RNG default, the seeded generator, permutation `<config>`
      and plural lenient fallbacks — 31 assertions, all measured against the reference.
      Still uncovered: **`#include` resolution and depth**, and the `known_variables` path.
      Start by establishing whether this engine resolves `#include` at render time at all
      or treats it as a host concern; the answer decides whether there is behaviour to
      assert. Expectations must be measured against the reference, never written by
      reading this port.
- [ ] **Cosmetic post-process remainder** — 21 fixtures, all in `render-postprocess.json`,
      listed in `../tests/known-failures.txt`. A scope decision, not a defect:
      [decisions/0002](decisions/0002-postprocess-remainder.md). Pick up only if a consumer
      needs URL/email shielding or Spanish sentence openers.
- [ ] **DPM packaging unverified.** The spec's shape matches DPM's definitive docs and its
      JSON content parses (the reader is YAML-only, but `VSoft.YAML` reads JSON). Whether
      the package actually *builds* is untested. DPM now has a Delphi to run on.
- [ ] **Repository is private.** Publishing is a decision, not a step.

## Done

- [x] Bootstrapped from the drafts; `.agents/` chain, hooks, CI and docs (2026-07-21).
- [x] Published to `investblog/spintax-win`; CI green on ubuntu, windows and shellcheck.
- [x] Delphi compatibility: sentinel encoding, `#def` dependency ordering, `{$IFDEF FPC}`
      around the mode directive. See [decisions/0003](decisions/0003-delphi-compatibility-audit.md).
- [x] Host UTF-8 contract documented in README; runner and demo declare it.
- [x] `W1050` eliminated in source via `CharInSet` (30 → 0 expected; **Delphi count not yet
      re-confirmed** — folded into the stale-measurement item above). FPC `4046` stays
      suppressed: measured to originate in FPC's own RTL, not in this code.
- [x] Dead locals removed (`hadTrailingNL`, `ch`, `f`).
