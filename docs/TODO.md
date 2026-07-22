---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

- [ ] **Repository is private.** Publishing is a decision, not a step.

## Done

- [x] **UTF-16 portability settled** (2026-07-22): kept in the source, dropped as an
      obligation. Not a supported platform, nothing gated on it, no dated claim to keep
      fresh -- but the `{$IFDEF UNICODE}` branches stay, because building the same source
      with a second compiler is what found the sentinel-encoding and `#def`-ordering
      defects and both were bugs in the FPC build too. `Spintax.Core.dspec` removed: it
      targeted a package manager nobody in this project's use case needs.

- [x] **Full post-process parity** (2026-07-22). All twelve reference steps; the whole
      corpus passes on FPC and Delphi. Supersedes [decisions/0002](decisions/0002-postprocess-remainder.md).

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
