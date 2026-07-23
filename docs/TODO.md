---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

- [ ] **Release the located diagnostics.** `TSpDiag` gained `Line`/`Column`/`EndLine`/
      `EndColumn` — a public, additive API change, so the next tag is a **minor bump**
      (`v0.2.0`), and `spintax-studio` then bumps its engine submodule off `v0.1.0`. Release
      is tag-driven and only on the user's explicit command.

## Done

- [x] **Validator diagnostics carry source positions** (2026-07-23). `TSpDiag` now has
      1-based `Line`/`Column`/`EndLine`/`EndColumn` on top of `Code`/`Severity`, so
      spintax-studio can draw squiggles and jump to errors without reimplementing the
      validator scan. Positions are best-effort, code-point columns, editor EOL, and
      explicitly **not** corpus-gated — `Code`/`Severity` and every verdict are unchanged
      (corpus still 168/0/4). The char-scan checks made this cheap; two collectors
      (`CollectOccurrences`, `FindPluralBlocks`) grew position overloads, and
      `variable.undefined` — which scans a rebuilt body with directive lines dropped — got a
      body→source offset map so it locates against the real source. Coordinates are reported
      against the original source through a stripped→source map, so `/# … #/` comments (which
      drop characters and inner newlines) don't shift positions — detection stays on the same
      stripped text, verdicts unchanged. `TestDiagPositions` (320 local, up from 304) pins
      line/column/span for the editor-critical codes, with a Cyrillic case that a byte-column
      implementation would fail and comment cases (before, after, and inside) handled by the
      strip map and the split start/end mapping.

- [x] **Post-process is linear again** (2026-07-22). It was quadratic: sixteen passes each
      accumulating with `res := res + s[i]`, plus a placeholder restore that ran one
      `StringReplace` over the whole text per shielded match.

      Same inputs, before and after, FPC 3.2.2 / i386-win32:

      | input  | before | after  |
      |--------|--------|--------|
      | 14 KB  | 0.11 s | 0.04 s |
      | 59 KB  | 0.57 s | 0.17 s |
      | 237 KB | 6.1 s  | 0.70 s |
      | 950 KB | 45 s   | 2.8 s  |

      The point is the shape, not the seconds: four times the input now costs about four
      times the work, where it used to cost seven to ten. 17x faster at the top of the
      range.

      A growable buffer replaced the per-character concatenation inside the post-process
      only, and the restore became one left-to-right pass with a dictionary lookup.

      The restore change is not unconditional, and the first cut of it was wrong. A single
      pass is identical to the reference's per-key loop only when the input carries no
      `#0` of its own; when it does, a caller-supplied token can name a key the shield
      really minted, and the reference substitutes the caller's text too. Step 12 now
      takes the fast pass only for input without `#0` and keeps the reference-shaped loop
      otherwise. Measured over 61 124 inputs, 59 870 of them carrying a literal `#0`:
      121 diverge under an unguarded single pass, 0 under the guard. Corpus 164/0/4,
      304 local assertions, two of which are those 121 cases and fail without the guard.

- [x] **Published** as `investblog/spintax-win`, public, with the family's badges,
      cross-links and topics. CI green on ubuntu, windows and shellcheck.
- [x] **The repository carries product only** (2026-07-22): 26 tracked files. The agent
      charter and tooling live on disk but are not tracked -- they are instructions for
      maintaining the engine, not something a reader can use, and keeping a second copy of
      the parity contract had already drifted into documenting a build command that fails.
- [x] **Full post-process parity** (2026-07-22): all twelve reference steps. The whole
      golden corpus passes, `PASS=168 FAIL=0 SKIP=4`, and `tests/known-failures.txt` is
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
