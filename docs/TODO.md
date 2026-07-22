---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

- [ ] **Post-process is quadratic in input size.** Measured on FPC 3.2.2 / i386-win32,
      `PostProcess=True`, a template of ordinary sentences with URLs, emails and
      abbreviations:

      | input  | time   |
      |--------|--------|
      | 14 KB  | 0.11 s |
      | 59 KB  | 0.57 s |
      | 237 KB | 6.1 s  |
      | 950 KB | 45 s   |

      Four times the input costs roughly seven to ten times the work. Two causes, both in
      `FullPostProcess`: every one of the sixteen passes accumulates its result with
      `res := res + s[i]`, reallocating per character, and the placeholder restore runs a
      `StringReplace` over the whole text once per shielded match.

      The spec lists performance as **allowed to diverge** from the reference, so this is
      not a parity defect -- but 45 seconds for a 950 KB template is a usability limit for
      a content-generation engine, and the reference is roughly linear over the same range.
      Fix is mechanical: a growable buffer instead of per-character concatenation, and a
      single left-to-right restore pass instead of one replace per key. Measure before and
      after; the corpus and `local_tests` are the safety net.

## Done

- [x] **Published** as `investblog/spintax-win`, public, with the family's badges,
      cross-links and topics. CI green on ubuntu, windows and shellcheck.
- [x] **The repository carries product only** (2026-07-22): 26 tracked files. The agent
      charter and tooling live on disk but are not tracked -- they are instructions for
      maintaining the engine, not something a reader can use, and keeping a second copy of
      the parity contract had already drifted into documenting a build command that fails.
- [x] **Full post-process parity** (2026-07-22): all twelve reference steps. The whole
      golden corpus passes, `PASS=164 FAIL=0 SKIP=4`, and `tests/known-failures.txt` is
      empty. Supersedes [decisions/0002](decisions/0002-postprocess-remainder.md).
- [x] **Surfaces no fixture can express are gated**: `tests/local_tests.dpr`, 292
      assertions, every expectation measured against the reference and each one proved to
      fail when its behaviour is removed -- line terminators, the nil-RNG default, the
      seeded generator, permutation `<config>`, plural lenient fallbacks, `#include`
      rendering, `knownVariables`, and the baked Unicode tables.
- [x] **UTF-16 portability settled** (2026-07-22): kept in the source, dropped as an
      obligation. Nothing is gated on it and no dated claim is maintained, but the
      `{$IFDEF UNICODE}` branches stay -- building the same source with a second compiler
      is what found the sentinel-encoding and `#def`-ordering defects, and both were bugs
      in the Free Pascal build too.
- [x] **Host UTF-8 contract** documented in README; runner and demo declare it.
- [x] Bootstrapped from the drafts; CI and docs in place (2026-07-21).
