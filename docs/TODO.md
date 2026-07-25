---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

Three pre-existing divergences, all measured by the review sweep of 2026-07-25, none of them
from this year's diffs, **all three verdict-moving** (§3 REQUIRED):

- [ ] **An unterminated `/#` swallows the rest of the document; the reference leaves it as
      text.** `StripComments` (`src/Spintax.pas`) drops from `/#` to end of input when no
      `#/` follows; the reference's `/\/#[\s\S]*?#\//g` simply does not match, so the text
      stays. `price /# note` renders `price ` here and `price /# note` there. Verdicts move
      with it: `/#` + LF + `#include "nope"` is **invalid** in the reference
      (`include.unknown-target`) and valid here; `/#` + LF + `{a` is `bracket.unclosed` there
      and clean here. 114 of 202 differences in a 3 000-case fuzz.

- [ ] **`PhpLtrim` in the malformed-directive check.** `src/Spintax.pas` uses PHP's charlist
      (` \t\n\r\0\x0B`) where the reference uses `/^[ \t]+/` (`validator.ts:112`), and splits
      on five terminators where the reference splits on `\n` only (`validator.ts:110`). So
      `<VT>#set %x% = A`, `<NUL>#set broken`, `x<CR>#set broken` and `x<U+2028>#set broken`
      all report `set.malformed/error` here and nothing in the reference — a valid template
      called invalid. Same charlist family as the `TryParseDirective` defect fixed in
      `v0.3.1`, whose commit noted `PhpRtrim` stays for the permutation scan and did not
      audit `PhpLtrim`'s other user.

- [ ] **An extra `variable.self-reference`.** `#def %x% = #set %x% = ` + LF + `#set %x% = A`
      → the reference reports `definition.duplicate-name/error`, this port adds
      `variable.self-reference/error`. The verdict is invalid either way, so this is a code
      set difference rather than a verdict one — the corpus gates codes, so it would fail if
      a fixture covered it.

- [ ] **Ask the family whether `#include<NBSP>"x"` is an include.** The reference spells the
      whitespace class out as ASCII "for PHP parity"; the PHP core and the plugin write `\s`
      under `/u`, and PCRE2 with `/u` also sets `UCP`, which makes `\s` match `\p{Z}` — NBSP
      included. If that is right, PHP accepts a line JS and this port reject, and the
      reference's comment has the reason backwards. Unmeasured: no PHP on this machine. This
      port follows `@spintax/core` either way (§2), so nothing here is blocked on it.

- [ ] **The definition graph is still quadratic.** After the sweep below, one shape remains:
      `SpValidate` on a `#set`/`#def`-heavy document — 19 → 320 → 4547 ms for 400 → 1600 →
      6400 definitions. What is left is the taint propagation and the cycle detection, which
      walk `TStringList.IndexOf` per reference and per definition. They decide
      `variable.self-reference` and `definition.circular`, so they want their own before/after
      differential rather than a ride on someone else's — a name→index map and DFS colours is
      the shape of the fix. Everything else is linear.

## Done

- [x] **`SpExtract` and `SpValidate` are linear in what a document holds** (2026-07-26,
      `v0.3.2`). Three O(document × items) terms, each measured before and after at 400 /
      1600 / 6400 items — 4× input per step:

      | | before | after |
      |---|---|---|
      | `SpExtract`, `#set`-heavy | 25 → 289 → 4704 ms | 0 → 0 → 15 ms |
      | `SpExtract`, `%ref%`-heavy | 53 → 914 → 11 390 ms | 3 → 7 → 15 ms |
      | `SpExtract`, `#include`-heavy | 3 → 31 → 500 ms | 0 → 0 → 15 ms |
      | `SpValidate`, `%ref%`-heavy | 88 → 1328 → 19 282 ms | 0 → 8 → 31 ms |
      | `SpValidate`, `#set`-heavy | 41 → 609 → 10 375 ms | 19 → 320 → 4547 ms (see Open) |

      - **Ordered-unique lists deduplicated by `TStringList.IndexOf`** — a linear scan per
        name, O(names²). `AddUniqueOrdered` keeps the order in the list and the membership in
        a dictionary. Keys compare exactly, which is the same answer, because every name
        reaching it is already `LowerAscii`-folded and include targets are exact by contract.
      - **A body rebuilt line by line** in both functions, `s := s + line`, which copies the
        accumulator every time. Neither needed one: `%name%` and `{?name?` cannot span the
        `#10` that joined the lines, and a line already knows its own source offset, so the
        scans run where the text lies. `SpValidate` dropped its per-character source map with
        it.
      - **One `SourceLineCol` walk from offset 1 per diagnostic** — the same defect the
        occurrence API had, still in `AddDiagAt`. The undefined-variable passes emit in source
        order, so they now use `AddDiagAtOrdered`, which resumes the walk. 6400 warnings: 6.4 s
        → 31 ms.

      Gated by a before/after dump: 4000 generated templates × five modes (extract, validate
      with and without the host lists, render with and without post-process), **byte-identical**
      across the change. The control — the same dump from the previous commit, which changed
      CR handling — differs in 63 lines, so the harness can see a change when there is one.
      That dump also caught the one thing the refactor did move: sharing a membership set
      between the `%var%` and `{?name?` scans reordered `extract().refs` when a name appeared
      in both syntaxes. Fixed to reproduce the two-pass order exactly.

      No timing assertion was added to the suite: the surviving times are 15-30 ms, below what
      `GetTickCount64` can resolve into a ratio, and a growth-shape gate on a shared CI runner
      fails on noise rather than on complexity. The measurements live here and in the spec
      instead.


- [x] **Three defects the same-day review found in the day's own work** (2026-07-25,
      `v0.3.2`), each measured against `@spintax/core` over a corpus built to ask the
      question the earlier ones could not — 699 cases, **control run 210 render / 8
      target-list / 9 verdict differences, zero after**:

      - **Which CR a directive line takes.** `v0.3.1` fixed CRLF and wrote the rule down as
        "CRLF only, a lone CR is never consumed". The `\r?` is greedy and takes the CR
        whenever `$` holds after it, which is end of input or *any* terminator: five of six
        followers, not one. See §5.0 — the wrong reason had reached five files.
      - **The include scans retried line starts a match had already swallowed**, where the
        reference's `/g` resumes at the match end, inventing a second include (and with a
        slug list, an `include.unknown-target` error) out of `#include "a` ⏎ `#include "` ⏎
        `b"`. `ResolveIncludes` had always resumed correctly; the three editor/validator
        scans had not. One helper now, `ResumeAfterInclude`.
      - **A CRLF-terminated `#include` reported a span containing its own line break.** The
        anchor's trailing class takes the CR, so the match ends between CR and LF — a
        position the editor line model cannot name. Span and `Text` now give the CR back, as
        `TSpDirective` documents and as `#set`/`#def` always did; a host replacing the span
        no longer deletes the line break.

- [x] **A directive line is trimmed the way the reference trims it** (2026-07-25, `v0.3.1`).
      Both halves of `(.*?)[ \t]*\r?$`, spec §5.0:

      | | reference | before |
      |---|---|---|
      | `#set %x% = A` + NUL | value `A\0` | `A` |
      | `#set %x% = A` + VT | value `A\x0B` | `A` |
      | `#set %x% = A` + FF | value `A\f` | `A\f` |
      | `#set %x% = A` + **CRLF** + `%x%` | `\nA` | `\r\nA` |
      | `#set %x% = A` + **CR** + `%x%` | `\rA` | `\rA` |

      The first three are the value trim: `PhpRtrim`'s charlist also eats `\0` and `\x0B`,
      which are part of the value in the family. The CRLF row was **not** the reported
      defect — the differential found it. The optional `\r` sits INSIDE the reference's
      match, so removing a directive line takes the CR with it and leaves the bare LF; a lone
      CR survives, because `$` would then have to hold after it. `TestLineTerminators` pinned
      the old behaviour with a comment claiming it was measured against the reference, and it
      had not been for that shape — a wrong expectation is as durable as wrong code.

      Knock-on, also measured: a CRLF directive line now contributes a bare LF, so runs of
      them reach the blank-run collapse exactly as LF lines always did, and a mixed run
      collapses only the part that became bare LFs.

      Gated by 720 cases against `@spintax/core` — 14 value tails × 3 line endings × 4
      shapes, plus the tail placed before the `=` and around the name — **control run 274
      differences, zero after**. Eleven checks added or corrected in `TestLineTerminators`
      (399 local, up from 386), corpus unchanged at 168/0/4.

- [x] **The `#include` resolver seam** (2026-07-25, `v0.3.0`) —
      [ADR 0004](decisions/0004-include-resolver-seam.md). `TSpContext` gained
      `IncludeResolver: TSpIncludeResolver` (abstract class, caller-owned, shaped like
      `TSpRng`) and `MaxIncludeDepth` (`0` = `SP_DEFAULT_INCLUDE_DEPTH` = 20). `nil` leaves
      the directive verbatim — the pre-`v0.3.0` behaviour, and the reference's with no
      resolver — so nothing moves for an existing caller.

      `SpRender` split into a public wrapper and `RenderDocument`, which is the reference's
      `renderAst`: directives, vars, `#def`, the tree walk, then the include pass over the
      RESULT. Post-process and the safety restore stayed in the wrapper, so they run **once**
      over the assembled document — the reference's order, and the reason a child never goes
      through the public entry point.

      The semantics are the family's and not the intuitive ones: the child is parsed and
      rendered on its own and its OUTPUT substituted, it inherits the runtime context and the
      RNG but not the parent's `#set`/`#def`, a child's own markup is sentinel-stripped like
      any author markup (so a neutralized value embedded in a template is removed, not
      restored), and an unknown target, a cycle (by ref string) or a chain past the cap
      resolves to `''`. Aliases are not cycles. The cap counts the include stack only.

      Gated by a differential the corpus cannot express — 52 cases against `@spintax/core`
      with a matching resolver on both sides, **48 of them different with the seam left nil**,
      zero with it wired — and 14 checks in `TestIncludeResolver` (386 local, up from 372).
      Corpus unchanged at 168/0/4, and the refactor was confirmed behaviour-neutral before the
      seam was used at all.

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
