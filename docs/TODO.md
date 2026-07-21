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

- [ ] **[BLOCKING A RELEASE] The Delphi parity measurement is stale.** The last full run
      is 2026-07-21 (`143/21/4`, failing set identical to FPC), and the engine has changed
      substantially since — a 28-site `CharInSet` sweep, the host codepage declaration,
      dead-local removal, the RNG default, and the line-terminator rewrite. FPC and CI
      cover Windows and Linux; **nothing covers Delphi but a human pressing Shift+F9**.
      Until that is re-run, README and `spec-pascal-port.md` describe an engine state that
      no longer exists.

      Two things to build there, not one: `tests/corpus_runner.dpr` **and**
      `tests/local_tests.dpr`. The latter has never been compiled by Delphi at all — its
      `{$IFDEF UNICODE}` branch for U+2028/U+2029 and its `in '..\src\Spintax.pas'` clause
      are unverified on that compiler.
- [ ] **Delphi parity is measured but not defended.** No licence available here grants
      `dcc32` — Starter never had it, and trials exclude the command-line compilers by
      design ([Embarcadero](https://support.embarcadero.com/article/44692)) — so the Delphi
      run cannot be gated by a hook or by CI. Architect trial expires ~2026-08-21.
      **Decide:** buy Professional+ and gate it, or accept a dated manual check and treat
      every string-width-sensitive edit as requiring a re-run.
- [ ] **Ungated surfaces: partly covered now.** `tests/local_tests.dpr` asserts line
      terminators and the nil-RNG default. Still uncovered, and still where the sibling
      ports' real bugs lived: `#include` resolution and depth, permutation `<config>`
      (`minsize`/`maxsize`/`sep`/`lastsep`), plural lenient fallbacks, and the
      `known_variables` path. Expectations must be measured against the reference, never
      written by reading this port.
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
