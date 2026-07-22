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

- [ ] **Re-measure Delphi after any engine change.** Last measured 2026-07-22
      (`164/0/4` corpus, `272/0` local -- 292 under FPC, the difference being twenty
      `{$IFNDEF UNICODE}` decoder assertions -- clean build). It is a manual IDE rebuild of
      `tests/corpus_runner.dpr` and `tests/local_tests.dpr`, and CI cannot gate it: no
      licence grants `dcc32` (Starter never had it; trials exclude the command-line
      compilers by design, [Embarcadero](https://support.embarcadero.com/article/44692)).
      **This is settled, not an open decision** -- see the Delphi purpose in
      `spec-pascal-port.md` sec.2. Buying a licence is not on the table.

      Verification survives the Architect trial expiring (~2026-08-21): **Delphi 12
      Starter is installed permanently and its IDE compiles**, Win32. That is enough for
      both binaries.

      Partly mitigated already: `build.sh` also builds the local suite with `-Co -Cr`,
      reproducing Delphi's Debug overflow/range checks under FPC -- verified to catch the
      exact `EIntOverflow` only Delphi had found. That closes one bug class, not the
      compiler difference.

- [ ] **DPM packaging: verify, or drop it.** `Spintax.Core.dspec` has never been built by
      DPM. But the reason Delphi is supported at all is source portability for another
      team (spec sec.2), not distribution through a package manager -- so decide whether
      the dspec earns its place before spending effort proving it works.
- [ ] **Repository is private.** Publishing is a decision, not a step.

## Done

- [x] **Full post-process parity** (2026-07-22). All twelve reference steps; the whole
      corpus passes on FPC and Delphi. Plan in `../.agents/plans/done/postprocess-parity.md`;
      supersedes [decisions/0002](decisions/0002-postprocess-remainder.md).

- [x] **Ungated surfaces are covered.** `tests/local_tests.dpr` — 51 assertions, every
      expectation measured against the reference — now gates line terminators, the nil-RNG
      default, the seeded generator, permutation `<config>`, plural lenient fallbacks,
      `#include` render behaviour and `knownVariables`. None of these can be expressed as a
      corpus fixture, and each one was proved to fail when its behaviour is removed.

- [x] Bootstrapped from the drafts; `.agents/` chain, hooks, CI and docs (2026-07-21).
- [x] Published to `investblog/spintax-win`; CI green on ubuntu, windows and shellcheck.
- [x] Delphi compatibility: sentinel encoding, `#def` dependency ordering, `{$IFDEF FPC}`
      around the mode directive. See [decisions/0003](decisions/0003-delphi-compatibility-audit.md).
- [x] Host UTF-8 contract documented in README; runner and demo declare it.
- [x] `W1050` eliminated in source via `CharInSet` (30 → 0 expected; **Delphi count not yet
      re-confirmed** — folded into the stale-measurement item above). FPC `4046` stays
      suppressed: measured to originate in FPC's own RTL, not in this code.
- [x] Dead locals removed (`hadTrailingNL`, `ch`, `f`).
