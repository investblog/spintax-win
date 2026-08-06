---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

Two pre-existing divergences, measured by the review sweep of 2026-07-25, neither from this
year's diffs (§3 REQUIRED). The third, the unterminated `/#`, was fixed on 2026-08-06 —
see Done:

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

- [ ] **Ask the family whether `#include<NBSP>"x"` is an include** —
      [spintax-js#55](https://github.com/investblog/spintax-js/issues/55), filed 2026-07-26
      with the measured JS table and four proposed `extract` fixtures; PHP still unmeasured.
      Nothing here is blocked on it (this port follows `@spintax/core`, §2), but if PHP wins
      the answer arrives as fixtures and the corpus turns red here first. The reference spells the
      whitespace class out as ASCII "for PHP parity"; the PHP core and the plugin write `\s`
      under `/u`, and PCRE2 with `/u` also sets `UCP`, which makes `\s` match `\p{Z}` — NBSP
      included. If that is right, PHP accepts a line JS and this port reject, and the
      reference's comment has the reason backwards. Unmeasured: no PHP on this machine. This
      port follows `@spintax/core` either way (§2), so nothing here is blocked on it.

- [ ] **The permutation-config extractors are looser than the reference's regexes.**
      Pre-existing, unchanged by the `v0.3.2` branch-gate fix, reachable only once a real
      key has already selected key form. `FindInt` treats `=` as optional where
      `MINSIZE_RE`/`MAXSIZE_RE` require it — `[<sep="-" minsize 5>…]` parses minsize=5 here,
      null in the reference (measured by the 2026-07-26 review agent against the actual JS).
      And `FindInt`/`FindStr` skip only `[' ',#9]` around `=` where the reference's `\s*`
      also takes LF/VT/FF/CR; same 4-char-vs-`\s` gap in the per-element `looksHtml` check
      in `ParsePermutation` (`PER_ELEM_HTML_RE`). The new `LooksLikeHtmlStartTag` /
      `HasConfigKey` use the full ASCII `\s` set already; align these older sites with a
      before/after differential over VT/FF/CR-bearing configs.

- [ ] **Expose a parsed template. The per-construct cost is now profiled, and it is the
      node tree — built and torn down on every render.** Phase timing (2026-08-06,
      `SpRender` split into parse / render / free):

      | template | parse | render | free | other |
      |---|---|---|---|---|
      | article 3.7 KB, PP off | 51.7% | 3.0% | 32.4% | 12.9% |
      | article 3.7 KB, PP on | 34.0% | 2.5% | 20.1% | 43.4% |
      | 64 KB dense, PP off | 56.7% | 3.5% | 35.8% | 4.1% |
      | 64 KB long options, PP off | 42.0% | 4.0% | 15.1% | 38.9% |

      Rendering is **3%**. Everything else is building the tree and destroying it: 84% of an
      article render, 93% of a dense one. `TNode` is a fat class carrying the fields of all
      six node kinds, so a literal costs a full allocate-zero-finalize, and `{a|b}` costs six
      objects plus a `TStringList` from `SplitTopLevel`.

      So the earlier allocation guess was right in kind and wrong in what it named: the
      string allocation removed then was noise beside the class churn.

      Micro-optimising the parser is a poor trade — dropping `SplitTopLevel`'s `TStringList`
      buys maybe 10–14% of parse, and collapsing literal-only options into the AST is a
      rewrite of the thing the corpus gates. **Caching the parse removes all 84%**: measured
      ceiling is ~6× on an article with `PostProcess=False` and ~2.2× with it on. `SpCompile`
      → `TSpTemplate` → render N times is additive, leaves parse and render code untouched,
      and is the shape a SER-like host actually needs. Note `#def` must still re-roll per
      render and its ORDER depends on runtime vars, so a compiled template caches the
      directive maps and the def node trees, not the ordering; and "the render never mutates
      the tree" wants a test, not a reading.

- [ ] **Ask the family whether a neutralized span should be exempt from the cosmetic
      stage.** The pipeline runs the post-process BEFORE the sentinel restore, so
      `neutralize` protects structural characters from the parser and nothing from
      typography: `#file[l.txt,1,S]` handed in through the context comes back as
      `#file[l.txt,1, S]` with the stage on. Measured identical in `@spintax/core`
      (2026-08-06), so this port is at parity and must not change it alone. But "passes
      through untouched" stops being true the moment the cosmetic stage is on, which is
      worth putting to the reference. Reported from real use — porting the GSA converter
      into the editor — and worked around there with `PostProcess=False`, which a converted
      GSA template wants anyway. Pinned by `tests/gsa_tests.dpr` so a family change shows up
      here first.

- [ ] **A value-equality conditional would collapse the GSA tag encoding.** `{?VAR?a|b}`
      tests only whether a variable is SET, so the dialect converter below expresses an
      n-way correlated choice as n−1 definitions and a chain of n−1 nested conditionals per
      block. With `{?VAR=x?a|b}` it would be one definition and one test — readable output
      instead of generated noise. A family syntax change: reference and corpus first, and
      worth raising only if something other than this converter wants it too.

## Done

- [x] **The definition graph is linear** (2026-08-06). `SpValidate` on chained `#set`s —
      the shape an editor meets, each macro referencing the next — took **23 959 ms at 400
      definitions**; it takes **6 ms**, and 6 400 take 114 ms where the old build would have
      needed hours. Flat definitions were already linear and stay so.

      Three causes, and only the first was the one the backlog had guessed: every lookup was
      a linear `TStringList.IndexOf` and every visit re-parsed the value's references; the
      cycle walk restarted at each definition without remembering what it had already
      cleared; and the taint propagation was a fixpoint sweep, which on a chain taints one
      more name per pass and so runs once per definition over every definition.

      Verdicts unchanged, asserted by a 4 000-document differential over cycle- and
      chain-heavy input against the previous build: **0 differences**, where three control
      mutations of the new code give 1 944, 817 and 799. Six local assertions pin the shapes
      the differential exists to protect.

- [x] **An unterminated `/#` no longer swallows the rest of the document** (2026-08-06).
      `StripComments` dropped from `/#` to end of input when no `#/` followed; the
      reference's `/\/#[\s\S]*?#\//g` simply does not match there, so the text stays. Not a
      cosmetic difference — it removed whole templates from the render and took their
      diagnostics with them (`/#` + LF + `{a` was `bracket.unclosed` in the reference and
      clean here), and it ate any ordinary URL carrying a fragment, `http://example.com/#top`
      being the everyday shape. That last one is why it moved up the list: it is the same
      engine behaviour the GSA front end had to work around, and it bit a real host.

      The fix looks for the closer before consuming anything and otherwise treats the `/`
      as the ordinary character it is, so scanning resumes inside the failed opener exactly
      as a regex engine retries at the next position — which is what lets a later
      well-formed comment still match.

      Ten local assertions, each measured against `@spintax/core`, plus a 3000-input
      differential over a `/#`-heavy pool comparing render AND validate: **0 differences**,
      against **1120** with the fix reverted. The corpus does not cover this shape either
      way, which is why it survived so long.

- [x] **A GSA SER dialect front end** (2026-08-06), `src/Spintax.Gsa.pas` +
      `tests/gsa_tests.dpr`, 94 checks in both an optimised and a `-Co -Cr` build.
      Optional, outside the corpus contract, so an existing SER template runs on this
      engine unchanged instead of the engine growing GSA syntax.
      See [decisions/0005](decisions/0005-gsa-dialect-front-end.md).

      Reading the macro guide rather than the feature request corrected two of its three
      claims: `~{a|b|c}` is *"all variations used but in a random order"*, which `[a|b|c]`
      already was, and spintags tag each OPTION and correlate by LABEL.

      The form the request actually described -- tag on the BLOCK, correlation by option
      INDEX -- was built, then measured in SER's own Article Manager and removed. Eight
      copies of one three-option block in a single article: untagged control
      `1 1 2 3 2 2 1 1`, the guide's per-option form `1 1 1 1 1 1 1 1`, the request's form
      `2 1 1 1 1 1 1 1`. Index correlation predicts eight identical digits with certainty,
      so SER does not do it; the guide's form correlating is real at p ~ 0.05%. Blocks with
      only some options tagged are now refused and handed to the host. The SER author's
      description of his own syntax does not match his engine, and the measurement is what
      to send him.

      Two rounds of review, and the second one is the one worth remembering. Every finding
      it raised lived in the gap between what the converter WRITES and what `SpRender` then
      renders — the suite had been asserting almost entirely on the former. `#file_links[…]`
      was unprotected because the name scan stopped at the underscore; `%related_url_link
      [ignore=a|b]%` had its arguments shuffled; and a block documented as "left exactly as
      written" was left in the template, where the engine read it as an ordinary spin and
      printed one random branch with the tag still attached. The rule that came out of it:
      a conversion may never leave the engine free to render a GSA construct as something
      else, so anything unconvertible is lifted OUT into a variable and reported.

- [x] **`SpRender` no longer pays for text it does not change** (2026-08-06). 64 KB of plain
      text carrying no spintax cost 15 ms; it costs 2.5 ms. Two causes, neither the parse
      tree. Four accumulators walked the whole document per render growing a string one
      character at a time (`SpStripSentinels`, `StripComments`, `ParseSequence`'s literal,
      `SpSafetyRestore`) — the `TStrBuf` added for the post-process had been scoped to it
      under a comment claiming nothing else was hot, which had never been measured. And
      `MatchesFoldedAt` allocated two strings per code point because `SpUpperCodePoint`
      returns one, times 46 abbreviations at every word start: 1383 ms of a 1606 ms
      post-process on a 1 MB render. Now an allocation-free ASCII fold (mixed pairs still go
      through the table — U+017F folds into ASCII) plus `SpUpperFirstCp` as a one-integer
      necessary condition, verified against `SpUpperCodePoint` over every code point to
      U+10FFFF, zero mismatches. Post-process on 1 MB 2133 → 421 ms; a 3.7 KB article with
      160 blocks 7.0 → 1.4 ms. Corpus 200/0/4, 411 local assertions in both builds -- the three new ones pin the
      folding fast path and the pre-filter, and each was proved to fail when its branch is
      mutated away.
      See `docs/spec-pascal-port.md` §4, "`SpRender`, and the price of doing nothing".

- [x] **The permutation config is gated on the family's two tests** (2026-07-26, `v0.3.3`).
      `ParsePermConfig` chose key form on a bare `Pos()` substring hit, so `[<separator>a|b]`
      dropped the separator word and `[<xminsize=2>a|b]` ran a `minsize=2` config the
      template never asked for (`FindInt` found the key inside the word); and the
      `looksLikeHtmlStartTag` guard was missing entirely, so a leading `<li …>…</li>` was
      eaten as config. Both branches now match the reference: the HTML guard first, then
      `\b(?:minsize|maxsize|sep|lastsep)\s*=`. Found by the cross-engine differential, pinned
      by three fixtures at `spintax-js@73af3ff` — the shared corpus is now **204 cases,
      200/0/4 here**. Review follow-up in the same tag: the ported `\s` sets include VT and
      FF (JS `\s` matches both, and they are ASCII); the looser pre-existing extractors are
      recorded in Open above.

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
