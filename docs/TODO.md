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
- [ ] **Delphi parity is measured but not defended.** No licence here grants `dcc32`
      (Starter never had it; trials exclude it by design), so the Delphi run cannot be
      gated. Any change to a `{$IFDEF UNICODE}` branch, to `#def` ordering, or to anything
      string-width-sensitive needs a manual Shift+F9 on `tests/corpus_runner.dpr` — a green
      FPC corpus does not cover it. Architect trial expires ~2026-08-21. Decide: buy
      Professional+ for a real gate, or keep a dated manual check.
- [ ] **Re-measure Delphi before any release.** The last full run is 2026-07-21
      (`143/21/4`, failing set identical to FPC). Treat it as stale after engine changes.
- [ ] **Nothing guards the Delphi fix.** The licence is Starter — no `dcc32` from the
      command line, so no hook and no CI can re-check it; each verification is a human
      pressing Shift+F9. Decide: a licence with the command-line compiler (Professional or a
      trial) and a real gate, or a dated manual check where any edit to an
      `{$IFDEF UNICODE}` branch requires a re-run.
- [ ] **Silence `W1050`** (`WideChar reduced to byte char in set expressions`, 31 warnings)
      with `CharInSet`. Cosmetic only — measured **not** to be a correctness defect
      ([RESULTS.md](../tests/delphi/RESULTS.md)); do not "fix" the 28 sites expecting a bug.
- [ ] **DPM packaging unverified.** The spec's shape matches DPM's definitive docs and its
      JSON content parses (the reader is YAML-only, but `VSoft.YAML` reads JSON). Whether
      the package actually *builds* is untested. DPM itself now has a Delphi to run on.

## Done

- [x] Project bootstrapped from the drafts; `.agents/` chain, hooks, CI and docs in place
      (2026-07-21).
