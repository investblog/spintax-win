---
type: note
status: active
tags: [backlog]
project: spintax-win
---

# Backlog

The single list of open work.

## Open

All three of the 2026-07-25 divergence sweep are closed, all on 2026-08-06 — the
unterminated `/#` in the morning's run, `PhpLtrim` and the extra
`variable.self-reference` in the evening's — and the corpus session has since verified them
and pinned the forms (see Done). What is left open is one syntax proposal and one known
ordering difference; the neutralize question was answered on 2026-08-07.

- [ ] **`include.unknown-target` is emitted before the `variable.undefined` warnings; the
      reference emits it after.** Found by the 2026-08-06 review over 5 000 include-bearing
      cases: the diagnostic MULTISET is identical to `@spintax/core` (`sort | diff` = 0) and
      1 184 lines differ in order alone. Pre-existing — identical at `f408fea`, so not from
      the comment or graph work — and codes plus severity are what §3 makes the contract, so
      no verdict moves. Worth closing anyway: an editor that lists diagnostics in engine
      order shows them in a different order than the reference would, and the corpus does not
      gate order. Filed upstream as
      [spintax-js#70](https://github.com/investblog/spintax-js/issues/70), where it turned out
      to be a FOUR-way split rather than a two-way one: this engine leads with the include
      diagnostic, `@spintax/core` appends includes last, the Python port sorts by source
      position, and both PHP engines return two separate lists and cannot express an order at
      all. The open question there is whether order is contract at all; the current answer is
      that it is not. Nothing to change here until that is settled.

- [ ] **Deeply nested conditionals in a plural count slot are quadratic when the branch is
      TAKEN.** `RecognizeConditional` finds the separator by scanning the body, so N nested
      truthy conditionals scan N + (N−1) + … characters: 2000 levels 54 ms, 4000 210 ms,
      8000 913 ms (2026-08-18). The reference shares it and is slower (393 / 1426 / 4510 ms),
      and upstream's own #67 commit says deep balanced nesting stays super-linear in every
      engine and that bounding input is a host job — the reference deployment caps a template
      at 8192 characters. Recorded rather than fixed: an exact fast version needs the
      separator scan's clamped, type-agnostic bracket counter precomputed, and a second
      reading of that rule is what the one-recognizer discipline exists to prevent. Both
      branches are now pinned in `TestPluralFormCounting`; spec §5.6 carries the numbers.
      Filed upstream as [spintax-js#71](https://github.com/investblog/spintax-js/issues/71)
      and reproduced on the reference — 238 / 822 / 2437 ms at 2k / 4k / 8k levels against
      this port's 54 / 210 / 913 — with the reading of the cause confirmed and the same
      decision taken there.
      Found by Codex review, which also caught that the first version of that section
      claimed linearity while measuring only the branch that cannot exhibit the cost.

- [ ] **`plural.count-macro` is reported once per BLOCK here and once per tainted REFERENCE
      in the reference.** Measured 2026-08-18 while adopting spintax-js#66:
      `#set %a% = {x|y}` + `#set %b% = {x|y}` + `{plural %a% %b%: one|two}` gives
      `["plural.count-macro","plural.count-macro"]` from `@spintax/core` and one diagnostic
      here — this loop `Break`s at the first tainted name, the reference's does not. Both
      anchor at the same span, so the second is a duplicate at identical coordinates, and
      the verdict is `invalid` either way. Not corpus-gated: expected diagnostics are matched
      as a SUBSET, so one where two are expected passes. Pre-existing, unrelated to the
      count-expansion work, and the same shape as the lesson AGENTS.md already records about
      `detectCycle` — a diagnostic COUNT can be a property of the walk. Removing the `Break`
      is the fix; it needs the two-cursor claim in §5.5 re-checked, since `count-macro` would
      no longer fire at most once per block.

- [ ] **A value-equality conditional would collapse the GSA tag encoding.** `{?VAR?a|b}`
      tests only whether a variable is SET, so the dialect converter below expresses an
      n-way correlated choice as n−1 definitions and a chain of n−1 nested conditionals per
      block. With `{?VAR=x?a|b}` it would be one definition and one test — readable output
      instead of generated noise. A family syntax change: reference and corpus first, and
      worth raising only if something other than this converter wants it too.

## Done

- [x] **The GSA lifter keys through a map** (2026-08-19, released as `v0.8.1`). `TLifter`
      kept two parallel `TStringList`s and found a key with `IndexOf`, which walks them, so
      converting a SER template cost O(n²) in the number of DISTINCT lifted macros — and a
      project template with a file spin per line is the ordinary shape, not a stress test.
      Measured independently of the change, best of three, n lines each lifting its own
      `#file[…]`: **179 → 8 ms** at 1 000, **735 → 16**, **2 820 → 30**, **11 421 → 60 ms**
      at 8 000; 4.1× / 3.8× / 4.05× per doubling before against 2.0× / 1.9× / 2.0× after.
      Output is byte-for-byte identical — a whole conversion dumped and compared across both
      trees over repeats, case pairs, mixed kinds and unsupported constructs, not only the
      shape the fix repairs. The case rule survived by TYPE rather than by a flag
      (`TStringList.IndexOf` folds by default and needed `CaseSensitive := True`;
      `TDictionary` compares `string` keys ordinally), which is a claim about the RTL and not
      about this unit — so both directions are now pinned and the suite is 96 checks. Names
      still come from a per-kind counter in first-encounter order, never from enumerating the
      map. Written by a parallel session on a branch; reviewed, re-measured and released
      here.

- [x] **Re-aligned to per-NAME circular-reference emission** (2026-08-18, engine issue #2 from
      [spintax-js#59](https://github.com/investblog/spintax-js/issues/59)). The family reversed
      the shape this port had deliberately reproduced eleven days earlier: one diagnostic per
      NAME that takes part in, or leads to, a cycle, not one per PATH. Per-path is exponential
      in a converging graph and re-walking every route IS the emission, so it could not be
      kept and bounded — 547 bytes took the reference deployment out with HTTP 503. Measured
      here before, on the corpus's own `validate/cycle-diamond-terminates` (507 bytes,
      twenty definitions over a two-cycle): **2 097 152 diagnostics in 7 949 ms**, and the
      corpus could not see it, because expected diagnostics are matched as a SUBSET and that
      case gates only that the engine answers. After: 22, in about a millisecond; a cycle of
      51 200 went 82 222 ms to 2 071 ms. `MarkCyclic` already
      computed the per-name set as a prune, so the change deletes the walk and emits from it;
      the node-index apparatus went with it. Verified by differential over 800 generated
      definition graphs against `@spintax/core` 0.6.0: 0 differences, control 91. The two
      canaries that pinned the old counts were rewritten IN PLACE with the reversal in their
      comments. Spec §5.3.

- [x] **The render-side expansion bomb bounded** (2026-08-18,
      [spintax-js#69](https://github.com/investblog/spintax-js/issues/69)). Sixty-two
      characters -- `#set %a% = %b% %b%` over `#set %b% = %a% %a%`, then any reference that
      makes the value expand -- killed the process: `EOutOfMemory` out of `SpRender` on a
      plural naming it, over 60 s with no answer on a bare reference or one inside a
      permutation. Old, not from this week; live in every engine of the family. Now bounded
      by `SP_RENDER_EXPANSION_BUDGET`, charged per substitution and checked BEFORE it, one
      budget per `SpRender` call including `#include` children; out of budget a reference is
      left LITERAL, which is what an unknown name already renders as, so no new output shape
      enters the language. Every shape answers in well under a second. Spec §5.8. The family
      settled the rule in `@spintax/core` 0.5.2 the same day: 1 MB, and the truncated output
      is **deliberately not parity-gated** -- the engines expand by different mechanisms and
      stop in different places, so each pins its own bound in its own suite. Two things the
      first cut here got wrong, both Codex-review findings: a value carrying no construct
      must not be charged at all (it cannot explode, and charging it truncated 2 MB of
      ordinary output and a ten-hop `#def` chain), and the refusal is on an EMPTY purse
      rather than on one the next substitution would overdraw. With both corrected this
      engine stops at the same byte as the reference on the bomb, which is a fact rather
      than a contract. The family's 0.5.3 -- the budget travelling on the call rather than on
      each rendered template -- needed no change here, since this port shared the purse from
      the first cut; measured flat at 1, 50, 200 and 500 include lines. What remains across
      the family is volume and time, not survival, and this engine's numbers are in §5.8:
      identical output to the byte, 3-5x the reference's time, linear in output at ~1.2 ms
      per KB.

- [x] **Conditional truthiness over the full whitespace class** (2026-08-18, found by Codex
      review of the two adoptions below). `{?...}` truthiness is parity-REQUIRED by spec §3,
      and every other engine decides it with `/\S/u`; this port tested six ASCII characters
      byte by byte, so a variable holding one U+00A0 was truthy here and falsy everywhere
      else and the wrong branch rendered. `IsJsSpaceCp` enumerates the class and
      `ConditionalTakesThen` walks code points. No fixture carries a Unicode space and
      neither did any of the 500 local checks; 22 now do, measured against the reference,
      with U+200B / U+0085 / U+3164 as the controls that keep the class from widening into
      "non-ASCII". Spec §5.7. Worth reporting upstream only as a note — the reference is the
      one that is right here.

- [x] **Caught up with the family's two plural fixes** (2026-08-18), corpus
      `PASS=254 FAIL=0 SKIP=4`, 542 local checks in both builds.
      [spintax-js#66](https://github.com/investblog/spintax-js/issues/66): the form count is
      now taken on the list the renderer will split -- definition values substituted first,
      every reference per pass -- and only where it is provably invariant; a bracket, a
      `KnownVariables` name, an undefined reference or a chain past 51 passes files no
      count-based verdict at all -- and at most 64 KB of expansion, the ceiling upstream
      added mid-adoption after a 62-character memory bomb (`#set %a% = %b% %b%` over
      `#set %b% = %a% %a%`, doubling every pass) crashed every engine in the family
      including this one. Three things about that budget are verdicts, and each was wrong
      here once: it bounds GROWTH rather than total length (a 65 KB plain form list is still
      two forms -- ported from upstream's work in progress before their own review caught
      it); it is counted in UTF-16 units, because a byte count made 40 000 Cyrillic
      characters a different verdict here than in the reference; and it is enforced DURING a
      pass, because one pass can build 300 MB out of a 75 KB acyclic template before any
      check runs, 3.5 s to 35 ms. The last two were Codex-review findings. This engine is where the original bug was found, a day earlier,
      while adopting `plural.locale-missing`; the two checks that pinned the wrong answers
      were written to fail when the family fixed it, and they did.
      [spintax-js#67](https://github.com/investblog/spintax-js/issues/67): a conditional in
      the COUNT slot now resolves before the numeric test, so a valid template is no longer
      silently erased -- textually, over spans, never rendered, because enumerations resolve
      after plurals. Spec §5.5 and §5.6.

- [x] **`plural.locale-missing` adopted, and it woke a latent quadratic** (2026-08-18).
      Issue #1, filed from [spintax-js#65](https://github.com/investblog/spintax-js/issues/65)
      after a pipeline shipped unresolved plural blocks into ~1000 live articles. The
      warning fires where no locale normalizes AND the form count is not the render default
      (`PluralArity('')`, asked of the table rather than written as `2`); the verdict never
      moves, and any locale replaces it with the real answer. All six shapes measured
      against `@spintax/core` 0.4.0 before a line was written; 18 checks in
      `TestPluralLocaleMissing`, four of them on the RENDER side, because the warning's claim
      is about what rendering does.

      **Codex reviewed the commit and found two real things.** (1) The first cursor fix
      shared ONE walk across a loop where a block can raise `plural.count-macro` AND one of
      the arity-family diagnostics at the same anchor, so the second call restarted the walk
      from offset 1 -- correct positions, 523 ms on 2000 such blocks; two cursors, each
      monotonic on its own, give 11 ms, and the positions of that shape are now pinned.
      (2) The validator counts the pipes it can see while the renderer counts them after
      expanding `%variables%`, so a form list grown or shrunk by a reference is judged on the
      wrong number in both directions. The reference does the same and `plural.arity` has
      always done it -- there it is worse, calling INVALID a template that renders correctly
      -- so it is a family contract hole, now qualified in spec §5.5 and pinned as-is by four
      checks. Worth raising upstream in spintax-js.

      **The issue predicted the corpus would not police this here. It did.** The new fixture
      `validate/plural-no-locale-arity-mismatch-warns` failed against this engine before the
      change: the runner matches expected diagnostics as a subset, and a missing expected
      diagnostic is a failure — the "warning does not move the verdict, so a silent engine
      still passes" reasoning holds only for a runner that checks the verdict alone (the PHP
      one). Corpus is 235 cases, this engine 231 + 4 `kind:rng` skips.

      **And it made a dormant defect expensive.** All four plural diagnostics used the
      rescan-from-offset-1 mapper — the sixth site of the `AddDiagAt` shape — which cost
      nothing while the no-locale path raised nothing. 2000 3-form blocks in 102 KB: 10 ms
      before, **1460 ms** with the warning, **10 ms** once the loop walked positions with
      resumed cursors (`locale=en`, quadratic since it was written, 1705 → 10 ms). Measured,
      not reasoned; the numbers are in spec §5.5.

- [x] **The family answered the neutralize question: the span is NOT exempt** (2026-08-07),
      and the escape hatch is `PostProcess=False`. Filed from this port on 2026-08-06 after
      the GSA converter met it in the editor; pinned by `@42d51c3` as two fixtures this
      engine already passes -- `neutralize/cosmetics-apply-to-neutralized-span` and
      `neutralize/postprocess-off-roundtrips-byte-exact`. So `#file[l.txt,1,S]` coming back
      as `#file[l.txt,1, S]` with the cosmetic stage on is the contract in every engine, not
      a divergence to fix here, and a host whose output is a payload rather than prose
      renders with the stage off. `tests/gsa_tests.dpr` pinned this before the corpus did and
      keeps pinning it; the difference now is that a family change would break the corpus
      first.

- [x] **The corpus session verified the three fixes and pinned the forms** (2026-08-07).
      `spintax-js@d6c5455` adds 15 cases over exactly this port's divergences --
      `validate/directive-check-*`, `validate/definition-last-wins-*`,
      `set/last-definition-wins`, `set/duplicate-cycle-renders-lenient`,
      `set/malformed-head-cr-directive-survivor`, `perm/config-*` -- on top of 13
      comment cases (`@8402cb8`) and the two neutralize answers (`@42d51c3`). The corpus is
      234 cases and this engine passes 230 with 4 `kind:rng` skips and an empty
      `known-failures.txt`. The `/m` survivor, the quote-aware `findConfigEnd` and `SEP_RE`
      without a `\b` are green here too.

      **The one failure that round was the harness, and both sides found it independently.**
      `fpjson` drops a `\u0000`, so `validate/directive-check-nul-line-is-text` reached the
      engine as `#set broken` and `invalid` was the correct answer to the wrong question. See
      the entry below; fixed in `tests/SpxJson.pas` the same evening, verified by a byte-level
      probe and by a mutated engine that then failed the fixture.

      **And the `PhpLtrim` divergence turned out to be the family's, not this port's.** The
      same bare `ltrim()` charlist was live in BOTH PHP engines -- a NUL producing a false
      `set.malformed` (`spintax-php@c41f3db`, `plugin@9b193bc`) -- and `spintax-py` had the
      other half of this port's own bug: an ANCHORED match over a copy with the terminators
      normalised, where the reference runs an `/m` SEARCH over the exact text
      (`spintax-py@620fad4`). A measurement
      taken here to close a Pascal backlog item found real bugs in three sibling engines.
      Worth remembering the next time a divergence looks like "just this port being wrong":
      the reference is the contract, but a shared ANCESTOR's habit -- PHP's trim charlist --
      travels into every port that reads that ancestor.

- [x] **Review follow-up on the same day's work** (2026-08-06). An external review of the
      three fixes above found one blocker and two documentation errors, and verifying them
      turned up a fourth thing nobody had looked at.

      **The faithful cycle walk was recursive over strings, and that is a defect.** The
      output was right and the cost was not: one cycle of 6 400 definitions took **99
      seconds** and 6 400 stack frames, where the walk it replaced took 113 ms. It was made
      iterative over node indices with an explicit stack (and deleted outright on 2026-08-18
      with the move to per-name emission -- see the top of this list) — 1 052 ms for the same document,
      25 600 now finishes at all, and depth is bounded by the node count instead of by the
      machine stack. The quadratic part is the contract (N diagnostics × an N-step walk, and
      `@spintax/core` pays 505 ms where this port pays 14 on a cycle of 400); the hashing and
      the frames were not. Output identical: the two 4 000-case differentials re-run
      byte-for-byte, and three control mutations each fail the assertions they should. Both
      shapes are now in the suite (`TestGraphStress`), which is the actual lesson — the first
      version shipped with neither, on a review-driven rewrite whose own spec section warned
      about exactly that.

      **The spec described regexes the reference does not have.** §5.4 gave the extractors a
      `\b`; `MINSIZE_RE` and friends have none, and `SEP_RE` has a lookbehind the text did
      not mention. The GATE has the boundary and the extractors do not, so a real key opens
      the door and `xmaxsize=1` then walks through it — measured in both engines over 200
      seeds, now pinned by four assertions. The port was right; only the document was wrong,
      which is the more dangerous of the two.

      **And the differential's size was misreported** — 3 000 permutation documents, not
      4 000. Corrected against the corpus file itself.

      **The corpus runner was mangling its own input.** Chasing the NUL case the family had
      just pinned showed FPC's `fpjson` DROPS a `\u0000` escape and turns every escape above
      ASCII into `?`. See §8 of the spec; the fix is in `tests/SpxJson.pas` and is verified
      by a byte-level probe plus a mutated engine that now fails the fixture.

- [x] **The last three §3 divergences, closed together** (2026-08-06), ahead of the corpus
      session that is pinning these forms. Each measured against `@spintax/core` the same
      day, each with a differential carrying a control run.

      **The malformed-directive shape test.** `checkDirectives` splits on **LF alone** and
      left-trims **spaces and tabs alone**, where this port split on five terminators and
      used PHP's charlist. `<VT>#set %x% = A`, `<NUL>#set broken`, `x<CR>#set broken` and
      `x<U+2028>#set broken` were all reported malformed here and are not directives at all
      to the reference — a valid template called invalid, the §3 verdict divergence. Two
      further things surfaced while measuring: the test is `DIRECTIVE_RE.test(trimmed)` with
      the regex `/gmu`, so a well-formed directive sitting after a CR **inside** the line
      satisfies it and nothing is reported.

      **Definitions are deduplicated by name, LAST one winning** — for the self-reference
      test, the cycle walk and the plural taint alike, because the reference builds a Map
      and overwrites. This port used every occurrence and resolved a name to the FIRST, and
      the backlog had only half of it: we invented diagnostics the reference does not give
      (`#set %x% = %x%` then `#set %x% = B`) *and missed ones it does* (`#set %a% = plain`
      then `#set %a% = %b%` with `%b%` pointing back — the reference reports the cycle
      twice, this port reported nothing). The taint had the same shape: a middle definition
      holding an enumeration tainted a name whose surviving value is a literal.

      The COUNT was wrong too, and that was not in the backlog at all. The reference did
      not deduplicate references and returned from only the current frame, so `#set %a% =
      %b% %b%` in a cycle reported three times where this port reported once. The walk was
      made the reference's own, kept from exploding by pruning at names that reach no cycle.
      **That contract was reversed on 2026-08-18** — one diagnostic per NAME, spintax-js#59 —
      and the walk is gone; the prune became the emitter. See the entry at the top of this
      list.

      **The permutation config extractors.** `MINSIZE_RE` and friends require the `=`, take
      the full ASCII `\s` around it, and are regexes, so a failed candidate is retried at
      the next position. This port made the `=` optional (`[<sep="-" maxsize 2>a|b|c]`
      rendered a random subset where the reference renders all three), took only space and
      tab, gave up after the first candidate, and accepted an unterminated quote.

      Three differentials against the reference, 11 000 generated documents: directive
      shapes 4 000, definition graphs with duplicates 4 000, permutation configs 3 000 —
      **0 differences** in all three. Seven control mutations fire on exactly the corpus
      they belong to and nowhere else: 316, 269, 108, 985, 29, 94 and 814. 25 new local
      assertions; the suite is 474.

      Also closed: **the NBSP `#include` question** ([spintax-js#55](https://github.com/investblog/spintax-js/issues/55),
      closed 2026-07-25). The ASCII class won and the corpus pins it; measured today,
      `#include<NBSP>"x"` yields no include in either engine, and a space or tab yields one.


- [x] **A template can be parsed once and rendered many times** (2026-08-06).
      `SpCompile` → `TSpTemplate` → `SpRenderCompiled`, additive; `SpRender` is unchanged
      and now runs the same two halves in sequence, so the paths cannot drift.
      See [decisions/0006](decisions/0006-compiled-template.md).

      Phase timing is what justified it: rendering is 3% of a render, and building plus
      destroying the node tree is 84% of an article and 93% of a construct-dense document.
      Per render — 3.7 KB article with the cosmetic stage off, **0.98 → 0.04 ms (25×)**; the
      same with it on, 1.53 → 0.68 ms; 64 KB of sentence-long options, 5.27 → 0.44 ms; a
      construct every five bytes, 52.3 → 1.90 ms. The projection had been ~6×; it came out
      higher because the sentinel strip, comment strip and directive extraction are cached
      too. With the cosmetic stage on the gain is small, because that stage is per render.

      The handle cannot be invalid: the constructor takes the template, so a bare
      `TSpTemplate.Create` does not compile, and a nil handle raises `ESpintax` instead of
      rendering an empty string in silence. Both states were reachable in the first cut and
      review found them.

      The tree is REUSED, so equivalence is asserted rather than argued: a 1500-template
      differential through both paths under one seed, cosmetic stage on and off, plus a
      second render of the same compiled template — 0 differences and 0 changes from reuse,
      where two control mutations give 385/109 and 4446/4225. Eight local assertions pin the
      shapes with state. What cannot be cached and is not: the `#def` roll, whose ORDER
      depends on the host's variables.

- [x] **The definition graph is linear** (2026-08-06). `SpValidate` on chained `#set`s —
      the shape an editor meets — took **23 959 ms at 400 definitions** and takes **8 ms**.
      Every shape is linear now:

      | shape | before | after |
      |---|---|---|
      | 400 chained definitions | 23 959 ms | 8 ms |
      | one cycle of 400 | 338 ms | 7 ms |
      | one cycle of 6 400 | (hours) | 113 ms |
      | converging DAG, 20 levels (914 bytes) | 89 ms | <1 ms |
      | converging DAG, 2 000 levels | (does not finish) | 71 ms |
      | 6 400 duplicate definitions of one name | 14 728 ms | 47 ms |

      **Five** causes, and the first round of work found three of them. Every lookup was
      a linear `TStringList.IndexOf` and every visit re-parsed the value's references; the
      taint propagation was a fixpoint sweep, which on a chain taints one name per pass and
      so runs once per definition over every definition; the cycle walk restarted at every
      definition. The first fix for that last one — remember what a completed start had
      cleared — helped the shape it was measured on and nothing else: a converging graph
      still re-explored shared subgraphs **exponentially**, and a document that is one big
      cycle was still walked once per definition. Review caught it, and the benchmark had
      not, because the benchmark was a chain with no cycle in it — the one shape the memo
      fixes.

      Now the reachability is computed once for the whole graph with an iterative
      colour walk. And the fourth cause was not in the graph at all: with every definition
      reporting, `AddDiagAt` re-walked the document from offset 1 per diagnostic, which is
      the resuming-cursor defect this file already records for `SpExtract`. Both loops take
      `AddDiagAtOrdered` now — and a review then found it a **fifth** time, in
      `definition.duplicate-name`, which is why one `#set`-heavy shape (the same name defined
      over and over) was still quadratic after the round that claimed every shape was linear.
      The pattern to grep for is `AddDiagAt` inside a loop over occurrences; the remaining
      sites (brackets, malformed directives) are pre-existing and still there.

      Verdicts unchanged, asserted by three differentials against the pre-rewrite build —
      12 000 documents in all, carrying 17, 1 944 and 2 856 circular-reference diagnostics:
      **0 differences**. Six control mutations across the two rounds give 1 944, 817, 799,
      860, 820 and 2 856.

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
