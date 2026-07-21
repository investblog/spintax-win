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

- [ ] **Publish the repo.** No git remote yet; `investblog/spintax-win` does not exist.
      CI (`.github/workflows/ci.yml`) has therefore **never run**. Every command in it was
      reproduced locally and passes (build, `-Sew -vm4046`, the corpus gate, shellcheck) —
      but the runner setup around them, and the corpus checkout, are unverified.
- [ ] **Windows CI leg: confirm the FPC install step.** `choco install freepascal` and the
      `C:\tools\freepascal\bin\i386-win32` PATH entry are written from the package's
      documented layout, not from an observed run. First CI run either confirms it or it
      needs a `where fpc` fix.
- [ ] **Cosmetic post-process remainder** — 21 fixtures, all in `render-postprocess.json`,
      listed in `../tests/known-failures.txt`. Scope decision, not a defect:
      [decisions/0002](decisions/0002-postprocess-remainder.md). Pick up only if a consumer
      needs URL/email shielding or Spanish openers.
- [ ] **Ungated surfaces have no local tests.** `#include`, permutation `<config>`, plural
      lenient fallbacks — no fixture can cover them (spec §8) and this port has no local
      test for them either. This is where the sibling ports' real bugs lived.
- [ ] **Three unused locals** in `src/Spintax.pas` (FPC notes 5025/5027 at lines ~454,
      ~1059, ~1513). Cosmetic; notes are not gated, only warnings are.
- [ ] **Delphi blocker: UTF-8 byte literals under a UTF-16 `string`.** Sentinels
      (`Spintax.pas:268,297,319`) and fullwidth braces (`:901–902`) are hard-coded UTF-8
      bytes. Correct under FPC, wrong under Delphi 2009+ — and it would break the mandatory
      safety restore silently. Audited in
      [decisions/0003](decisions/0003-delphi-compatibility-audit.md); deliberately **not**
      fixed blind, because no Delphi here can prove the fix. Needs Delphi CE locally (GitHub
      Actions has no free Delphi runner), or drop the Delphi claim.
- [ ] **DPM packaging unverified.** The spec's shape matches DPM's definitive docs and its
      JSON content parses (the reader is YAML-only, but `VSoft.YAML` reads JSON). Whether
      the package actually *builds* is untested — that needs DPM, which needs Delphi.

## Done

- [x] Project bootstrapped from the drafts; `.agents/` chain, hooks, CI and docs in place
      (2026-07-21).
