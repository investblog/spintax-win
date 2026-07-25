---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

- [ ] **Add the `#include` resolver seam** — see
      [ADR 0004](decisions/0004-include-resolver-seam.md), accepted 2026-07-25. `TSpContext`
      gains `IncludeResolver: TSpIncludeResolver` (abstract class, caller-owned, like
      `TSpRng`; `nil` = today's behaviour) and `MaxIncludeDepth` (`0` = the family's 20).
      Resolution runs at the end of a document's render, before post-process; the child is
      parsed and rendered on its own, inherits the runtime context but not the parent's
      `#set`/`#def`, shares the RNG, and an unknown target, a cycle (by ref string,
      case-sensitively) or depth ≥ 20 resolves to `''`. Additive → minor bump `v0.3.0`.
      Gated by a differential against `@spintax/core` with a matching resolver on both sides,
      plus local tests for cycles, aliases, the depth cap and a child emitting neutralized
      markup — the corpus schema has no include-resolution field. Unblocks
      `spintax-studio`'s ADR 0003, which stops expanding includes itself.

- [ ] **A `#set`/`#def` value is right-trimmed with PHP's `trim` charset, not the
      reference's.** `TryParseDirective` ends with `PhpRtrim`, which strips space, `\t`, `\n`,
      `\r`, `\0` and `\x0B`; the reference's `DIRECTIVE_RE` ends `(.*?)[ \t]*\r?$`, which
      strips only spaces, tabs and one `\r`. Measured 2026-07-25, rendering
      `#set %x% = A<c>` + LF + `[%x%]`:

      | trailing character | reference | here |
      |---|---|---|
      | space / `\t` | stripped | stripped |
      | `\f` | kept | kept |
      | `\x0B` (VT) | **kept** | stripped |
      | `\0` (NUL) | **kept** | stripped |

      A render-output divergence on the deterministic surface, so a defect by §3 — reachable
      only with a literal NUL or vertical tab at the end of a directive line, which is why
      neither the corpus nor 86 419 include-shaped inputs found it. Found while checking the
      directive rule against the reference alongside the `#include` anchor. Fix is one line,
      but it changes render output, so: its own commit, with its own differential.

- [ ] **`SpExtract` is superlinear in directive count.** 1600 directives in an 80 KB
      document: `SpExtract` 281 ms against `SpExtractDirectives` 5 ms; 800 directives at the
      tail of a 124 KB document, 84 ms against 7.8 ms. It builds its body by appending line
      by line and dedupes names with `IndexOf`, both O(n²)-shaped, and `SpValidate` scans the
      same way. Nothing is wrong with the output, but a host that calls either on every
      keystroke pays for it — `spintax-studio` has been told to debounce.

## Done

- [x] **`#include` targets are compared exactly** (2026-07-25, `v0.2.2`). `KnownIncludes`
      membership in `SpValidate` and the `Includes` dedup in `SpExtract` went through
      `TStringList.IndexOf`, which ignores case; the reference uses a `Set` and
      `Array.includes`, and its extract docblock says slugs are left "as authored" where every
      other name it collects is lower-cased. A slug is a host identifier, not a variable name.

      | | reference | before |
      |---|---|---|
      | `#include "OK"` with `knownIncludes ['ok']` | **invalid** | valid |
      | `#include "a"` + `#include "A"` | two targets | one |
      | `#include "путь"` + `#include "ПУТЬ"` | two targets | one |

      A verdict divergence — and it **shipped in `v0.2.1`**, because the 86 419-case anchor
      differential could not ask the question: every target in that corpus matched the slug
      list in case. The third time this repository has been bitten by a green run over a
      corpus incapable of expressing the counterexample.

      Fixed with an exact-comparison helper rather than the list's `CaseSensitive`, which
      belongs to the caller and would re-sort a sorted list. Gated by a second differential —
      3 732 records over 933 sources × 4 slug lists, including case-differing pairs and an
      anchor regression subset: **control run 16 include-list and 108 verdict differences,
      zero after**. Five checks in `TestIncludeAnchor`, 372 local checks in both builds.
      `TSpDirective`'s doc comment, which stated the old behaviour as intentional, went with
      it.

- [x] **`#include` is recognised the way the family recognises it** (2026-07-25). One
      matcher, `MatchIncludeAt`, called by `SpExtract`, `SpValidate` and
      `SpExtractDirectives`, holding the reference's anchor
      `/^[ \t]*#include[ \t\n\r\f\x0B]+"([^"]+)"[ \t\n\r\f\x0B]*$/gmu` — the same one the PHP
      core and the plugin use. The port had read it as "`#include` at a line start, then the
      first quoted string on the line": looser on five shapes, stricter on one.

      | input | before | after (= reference) |
      |---|---|---|
      | `#include "frag" junk` | include, **invalid** | plain text, **valid** |
      | `#include"frag"` | include, **invalid** | plain text, **valid** |
      | `#include ""` | include (empty target), **invalid** | plain text, **valid** |
      | `#includes "frag"` | include, **invalid** | plain text, **valid** |
      | `#include "frag" "ok"` | include, **invalid** | plain text, **valid** |
      | `#include`⏎`"frag"` | plain text | include, **invalid** |

      `include.unknown-target` is an error, so the loose half was calling valid templates
      invalid — a **verdict** divergence, REQUIRED parity by §3, and invisible to a corpus
      carrying two plain `#include` cases. Present since the port was bootstrapped.

      The cross-line form is why this is a matcher over the text and not a test on one line:
      the rule's whitespace class holds `\n` and `\r`, so both gaps around the target may run
      past a terminator, and `SpExtractDirectives` then reports a span that crosses source
      lines — which is what a host replacing it has to remove. NBSP is deliberately NOT
      whitespace here: the reference writes the ASCII class out instead of using `\s`,
      because JavaScript's `\s` is Unicode-aware and PHP's under `/u` is not.

      Gated by a differential the corpus cannot express: 86 419 include-shaped inputs
      generated once and answered by `@spintax/core` (both `extract().includes` and the
      `include.unknown-target` count with a slug list), fed to both engines from that one
      file. **Control run against the old rule: 18 487 include-list and 15 758 verdict
      differences. After: zero.** Twenty-one checks in `TestIncludeAnchor` pin the readable
      cases and one more pins the cross-line span, 367 local checks in both builds, corpus
      unchanged at 168/0/4.

- [x] **The editor surface is released as `v0.2.0`** (2026-07-25). Two additive, public API
      changes ride the tag: `TSpDiag` gained `Line`/`Column`/`EndLine`/`EndColumn`, and
      `SpExtractDirectives` reports every `#set`/`#def`/`#include` occurrence with its span,
      value and consumed line. Additive, so a minor bump. CI ran the full suite on the tagged
      commit — build, `-Sew`, golden corpus and both local suites on ubuntu and windows,
      shellcheck — and the gated `release` job published from it. `spintax-studio` can now
      bump its engine submodule off `v0.1.0`; its M0 is written against both additions.

- [x] **Directive occurrences are reportable** (2026-07-25). `SpExtractDirectives` returns
      every `#set` / `#def` / `#include` the renderer sees — source order, duplicates kept,
      each with kind / name / value, the consumed line, and the line's span in the ORIGINAL
      source under the `TSpDiag` position contract.

      It exists because `SpExtract` deduplicates: one entry stands for a target that is both
      commented out and live, so a host substituting `#include` **by name** expands the
      commented copy too — and comments do not nest, so an included fragment carrying its own
      `/# … #/` then escapes the comment it landed in, leaking text and a stray `#/` into the
      output. Measured on a Studio prototype before this landed. Reporting occurrences also
      keeps the comment rule and the five line terminators here instead of copied into every
      host; `spintax-studio` needs the same list for three things (expanding includes,
      rendering a selected fragment with the document's macros in scope, showing macro values
      in its variables panel) and `SpExtract` serves none of them.

      The positions work already built the pieces: `StripComments` fills the stripped→source
      map, `TryParseDirective` and the include rule are the renderer's own, and
      `MapStart`/`MapEnd` translate the span. Nothing about parsing or verdicts moved —
      corpus unchanged at 168/0/4.

      **The first version of this was not cheap, and the benchmark that said so measured the
      wrong dimension.** `SourceLineCol` rescans the source from offset 1, so two calls per
      directive cost O(directives × length): 400 directives at the END of a 124 KB document
      took 628 ms against 32 ms for the same 400 at its start — the same document, so the
      published "5 ms on a 55 KB document" was true only of the six-directive shape it was
      taken on. Review caught it. The walk now resumes from where the previous span left it
      (`CursorLineCol`, one loop shared with `SourceLineCol` so the two line models cannot
      drift): measured 1.0 source characters stepped per document character with zero
      restarts, 7.8 ms head **and** tail, and flat from 50 to 800 directives where it used
      to run 63 → 881 ms. `SpExtract` is now the slower of the two on a directive-heavy
      document (281 ms against 5 ms at 1600 directives) for reasons of its own — see Open.

      `TestExtractDirectives` runs 25 checks (345 local, up from 320) covering the
      commented-vs-live case, kept duplicates against `SpExtract`'s dedup, comment-shrunk
      spans on both sides of a directive, CRLF/CR lines, U+2028/9 (which split a directive
      but do not advance `Line`), a code-point column on Cyrillic, name casing, the three
      line-anchoring rules, and both directions of the raw-sentinel divergence, each pinned
      against the render that disagrees with it. Five were confirmed to fail when the scan
      is pointed at the raw source instead of the stripped text — the control run this
      repository's own lesson demands.

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
