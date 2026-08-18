---
type: decision
status: active
tags: [spec, parity, port, pascal]
project: spintax-win
---

# spintax-win — the governing spec

The parity contract for the Object Pascal port. Code follows this doc: a behavior change
is justified here first, then implemented, then proved against the corpus.

## 1. What this is

`unit Spintax` — a zero-dependency Object Pascal implementation of the spintax.net
superset: enumerations `{a|b|c}`, permutations `[a|b|c]` with `<config>`, scoped variables
`%name%`, value-driven conditionals `{?VAR?a|b}`, locale-aware plurals, `#set` / `#def`
directives, `neutralize` shielding, `extract`, and a static `validate`.

Free Pascal 3.2.2+, `{$mode delphi}`. MIT. Also compiles unchanged under a UTF-16
Object Pascal compiler, which is kept but not maintained (§2).

## 2. Position in the family

| repo | package | role |
|------|---------|------|
| `spintax-js` | `@spintax/core` (TS, MIT) | **reference engine + home of the golden corpus** |
| `spintax-php` | `spintax/core` (MIT) | sibling port |
| `spintax-py` | `spintax-core` (MIT) | sibling port |
| `spintax` | WordPress plugin (**GPL**) | origin engine — behavior reference only |
| **`spintax-win`** | this repo | **this port** |

**Licence boundary.** The PHP plugin is GPL. Transcribing it would pull GPL into an MIT
package. Reimplement from the behavior contract plus the corpus. `@spintax/core` is our
own MIT code and IS a legitimate reference — mirror its *behavior*, never its TypeScript.

### Portability to a UTF-16 compiler: kept, not maintained

The source compiles unchanged under a UTF-16 Object Pascal compiler as well as FPC. That
is **not a supported platform**: nothing is gated on it, no build is required before a
release, and no claim about it is maintained.

It is kept because it costs nothing and it paid for itself. Building the same source with
a second compiler surfaced defects the corpus could not, and two of them were bugs **in the
FPC build too** — see §7. Delete the `{$IFDEF UNICODE}` branches and that second opinion is
gone for good; leaving them costs a conditional in a handful of places.

## 3. Parity: required, allowed, non-goal

**REQUIRED** — divergence here is a defect:

- accepted syntax surface (what parses, and what renders verbatim instead of throwing)
- `validate` verdicts (a template is invalid iff some diagnostic has severity `error`)
- plural grammar buckets per locale
- `{?…}` truthiness
- directive semantics: **`#set` is a macro** — re-rolled at every reference;
  **`#def` resolves once per render** and holds
- the post-process pipeline — *to the extent it is implemented*, see §4

**ALLOWED to diverge:** RNG selection results, internal architecture, diagnostic message
strings, performance.

**NON-GOAL:** cross-engine RNG-sequence parity. A seeded PRNG is reproducible *within* an
engine, not identical across engines. The deterministic fixtures inject an RNG strategy
precisely so they do not depend on it.

## 4. Measured state

Run on FPC 3.2.2 / i386-win32 against `spintax-js/packages/conformance/fixtures`
(258 cases total, 2026-08-18 — the corpus grew on 2026-08-06 with the cases the family
pinned from this port's divergences, once more with `plural.locale-missing` (§5.5), and
again the next day with the two plural fixes §5.5 and §5.6 describe):

| fixture file | cases | passing |
|---|---|---|
| render-semantics | 80 | 80 |
| validate | 70 | 70 |
| render-postprocess | 43 | 43 |
| render-deterministic | 16 | 16 |
| comments | 13 | 13 |
| extract | 12 | 12 |
| neutralize | 10 | 10 |
| render-rng-selection | 10 | 10 |
| render-rng | 4 | — skipped by design (within-engine reproducibility only) |

**`PASS=254 FAIL=0 SKIP=4`** — the whole corpus, the 4 skips being `kind:rng` render
cases, which are engine-private by design.

The same result was measured under a UTF-16 compiler when that portability was last
exercised (`tests/delphi/RESULTS.md`). Not maintained -- see §2. The runner is one source
for both compilers; `tests/SpxJson.pas` is the only place their APIs differ.

`build.sh` compiles the local suite a second time with `-Co -Cr`, overflow and range checks
on. That is gated on every push, and it is worth keeping on its own terms: the PRNG mixer
wraps by design and a checks-on build is the only thing that catches an unintended
overflow elsewhere.

[`tests/known-failures.txt`](../tests/known-failures.txt) is empty and gated in both
directions: any failure blocks a push, and a case that starts passing must be recorded
rather than absorbed.

### The cosmetic post-process is now a full port

All twelve steps, in the reference's order: shield URLs / `mailto:` and `tel:` URIs /
emails / bare domains / decimals / multi-part and single-token abbreviations into
placeholders, collapse space runs, punctuation spacing, bind Spanish openers to their
word, then capitalize first / after sentence punctuation / after block tags / after line
breaks, restore and trim.

Two things about it are easy to get wrong and are written down because they were:

- **Order is load-bearing.** Shielding must precede capitalization or the engine
  capitalises inside `example.com` and after `e.g.`; `mailto:` must be shielded before
  the email rule or the address is carved out from under its prefix; the opener must bind
  to its word before capitalization, or the capitalizer sees a space.
- **The reference does not use one flag set.** `CAP_AFTER_BLOCK_RE`, `EMAIL_RE`,
  `DOMAIN_RE` and `SINGLE_ABBR_RE` are `/giu/`, where property escapes are case-folded;
  the rest are strict. See §7 hazard 6.
- **The stage runs BEFORE the sentinel restore, so `neutralize` does not protect against
  it.** Neutralize shields structural characters from the PARSER; by the time the cosmetic
  passes run, a neutralized span is ordinary text to them, and only the characters that are
  still sentinels survive untouched. `#file[list.txt,1,S]` handed in through the context
  comes back as `#file[list.txt,1, S]` — brackets intact because they are sentinels, the
  comma respaced because it is not. Measured identical in `@spintax/core` on 2026-08-06, so
  it is the family's contract and not this port's to change; a host whose output is a
  payload rather than prose renders with `PostProcess=False`. Put to the family the same day
  and **answered on 2026-08-07: the span is not exempt** — `neutralize` shields structure
  from the parser, never typography from the cosmetic stage — with `PostProcess=False` as the
  escape hatch. Both halves are now corpus fixtures
  (`neutralize/cosmetics-apply-to-neutralized-span`,
  `neutralize/postprocess-off-roundtrips-byte-exact`), so a change of mind upstream breaks
  the gate here before it reaches a user.

This **reverses** [`decisions/0002`](decisions/0002-postprocess-remainder.md), which
recorded the minimal stage as a deliberate scope decision.

### `SpRender`, and the price of doing nothing

`SpRender` had never been measured; the editor-side pair above had. The number that made the
gap obvious: **64 KB of plain text carrying no spintax at all cost 15 ms** — the engine had
nothing to select, nothing to substitute, and still spent that. Two causes, neither of them
the parse tree.

**Per-character accumulation on the whole document.** `TStrBuf` already existed, added when
the post-process was found to be quadratic, but it was scoped to the post-process under a
comment stating that "concatenation elsewhere is not on a hot path". That was never measured.
Four accumulators walk the entire document on every single render — `SpStripSentinels`,
`StripComments`, `ParseSequence`'s literal, `SpSafetyRestore` — and each grew its result one
character at a time, reallocating per character. `ExtractDirectives` did the same per line,
`SplitTopLevel` per character of every option, `RenderNodes` per node. They now share the
buffer, and the two sentinel passes return the argument untouched when the document holds no
sentinel, which is the ordinary case.

**A string allocation per code point, 46 times per word.** `MatchesFoldedAt` compared
`SpUpperCodePoint(a) <> SpUpperCodePoint(b)`, and that function returns a **string** because a
few code points uppercase to more than one character. `ScanSingleAbbr` calls it for all 46
abbreviations at every word start, so folding cost two heap allocations per code point per
abbreviation. It was 1383 ms of the 1606 ms post-process on a 1 MB render — 86% of the stage,
in a step that shields `etc.` and `Mr.`.

Two fixes. Where both code points are ASCII the mapping is exactly `'a'..'z' → -32`, verified
against the table over all 128, so it is taken without allocating; only a mixed pair still goes
through the table, because a non-ASCII code point can fold **into** ASCII (U+017F → `S`) and
short-circuiting that would drop a real match. And `SpUpperFirstCp` gives the first code point
of the uppercase mapping without building the string, which makes `GAbbrevFirstUp[k] <> upHere`
a one-integer necessary condition for a fold-match — it can reject a candidate but never a
match. That equality was checked exhaustively against `SpUpperCodePoint` over every code point
to U+10FFFF: zero mismatches. A first attempt bucketed the abbreviations by ASCII first letter
instead and bought nothing, because 28 of the 46 are Cyrillic and the ASCII branch never ran.

Measured on the same machine, FPC 3.2.2 / i386 / `-O3`, per render:

| 64 KB template | before | after |
|---|---|---|
| plain text, no spintax, `PostProcess=False` | 15.4 ms | 2.5 ms |
| plain text, no spintax, `PostProcess=True` | 181 ms | 25 ms |
| sentence-long options, `PostProcess=False` | 17.3 ms | 3.3 ms |
| sentence-long options, `PostProcess=True` | 66.2 ms | 10.8 ms |
| `{a\|b}` every five bytes, `PostProcess=False` | 45.3 ms | 38.8 ms |

and end to end: a 3.7 KB article with 160 spin blocks 7.0 → 1.4 ms with the post-process on,
1 MB of flat spintax 2133 → 421 ms with it on and 297 → 124 ms with it off.

The one row that barely moves is the dense one, and what is left there is **not** explained
yet. The cost scales with the number of CONSTRUCTS, not with bytes: the marginal cost per
construct is 3.0 µs measured on the sparse template (468 constructs) and 2.96 µs on the dense
one (13 107), the same 64 KB either way. The obvious story — a `TNode`, a `TNodeList` and a
`TStringList` allocated per construct, so allocation-bound — was asserted here first and then
tested: removing one allocation per option (`FlushLiteral` reserved a fresh buffer even when
the parse was finished with it) moved the dense figure by less than the noise floor,
40.76 ms against 40.81 ms as the minimum of six interleaved runs. The allocation was real
and the removal is kept, but the explanation did not survive its own measurement, and this
paragraph is not going to carry a second unmeasured one. What is known: ~3 µs per construct,
flat in document size, cause unattributed.

`SpRender` also reparses the template on every call, which is pure waste for the host that
renders one template thousands of times; exposing a parsed template is an API change and is
not in this one. Both are open.

## 5. Public API

```pascal
function SpRender(const Template: string; const Ctx: TSpContext): string;
function SpCompile(const Template: string): TSpTemplate;          { = TSpTemplate.Create }
function SpRenderCompiled(Tmpl: TSpTemplate; const Ctx: TSpContext): string;
function SpNeutralize(const Value: string): string;
function SpSafetyRestore(const Text: string): string;
function SpStripSentinels(const Text: string): string;
function SpExtract(const Src: string): TExtractResult;
function SpExtractDirectives(const Src: string): TSpDirectiveList;
function SpValidate(const Src, Locale: string; KnownIncludes: TStringList): TSpDiagList;
function SpValidate(const Src, Locale: string;
                    KnownIncludes, KnownVariables: TStringList): TSpDiagList;
function NormalizeBaseLang(const Locale: string): string;
function PluralArity(const BaseLang: string): Integer;
```

`SpCompile` parses a template once so it can be rendered many times, which matters because
rendering is 3% of a render and the node tree is 84% of one (§4). `TSpTemplate` is opaque:
it holds a single `TObject`, so the node tree stays an implementation detail and does not
become part of anything anyone can depend on. The constructor takes the template, so a
handle without one cannot be built, and `SpRenderCompiled` raises `ESpintax` on a nil
handle — the one error type this unit has, raised on programmer error and never on template
content, which is the rule the reference states for its own.

A compiled template renders exactly what `SpRender` renders from the same source, asserted
by a 1500-template differential through both paths under one seed with the cosmetic stage on
and off. What is cached is the sentinel strip, the comment strip, the directive extraction,
the body's tree and each `#def` value's tree. What is **not**, and cannot be, is the `#def`
ROLL: a definition resolves once per render and its ordering depends on the host's
variables, because a runtime variable of the same name outranks it. `#include` children are
compiled per render too — their source comes from the resolver at render time. See
[`decisions/0006`](decisions/0006-compiled-template.md).

`TSpContext` carries the variable map (`TStrMap = TDictionary<string, string>`), the
locale, a `PostProcess` flag, and an injected `TSpRng`. The RNG seam ships `TFirstRng`,
`TLastRng`, `TSequenceRng` and a seeded `TMulberry32Rng` — the first three are what the
deterministic fixtures drive.

`SpValidate` returns `TSpDiagList` (`TList<TSpDiag>`). Each `TSpDiag` carries `Code` and
`Severity` — the parity contract, the only fields the corpus gates — plus **best-effort
source positions** `Line`, `Column`, `EndLine`, `EndColumn` for editors (squiggles,
jump-to-error, LLM-repair prompts). Invalid iff any diagnostic is severity `error` — that
is the verdict an editor or an LLM-repair loop keys off.

The positions are deliberately outside the parity claim and are **not** required to match
`@spintax/core` or the PHP validator, which report their own line/column. The contract:

- all 1-based; **0 means unknown**, a valid and common answer — a finding that cannot be
  cheaply and safely located stays `0/0` rather than guessing;
- `Column`/`EndColumn` count **code points** from the line start, so the value is identical
  under FPC (UTF-8) and a UTF-16 compiler and points at a character, not a byte — the corpus
  is full of Cyrillic, where a byte column would land mid-glyph;
- `Line` uses editor end-of-line semantics (`\n`, `\r\n`, `\r` each one line), on purpose
  distinct from the engine's `/gmu` render-time line model;
- `End*` give a span when one is cheap, else 0.

The editor-critical codes are located (brackets, malformed `#set`/`#def`, undefined
variables, unknown includes, plural arity, and the rest); `tests/local_tests.dpr`
(`TestDiagPositions`) pins the exact line/column/span for a representative set, including a
Cyrillic case that a byte-column implementation would fail. Positions add fields to a record
whose old readers used only `Code`/`Severity`, so they stay source-compatible.

Coordinates are reported against the **original source**, not the comment-stripped text the
validator scans. `/# … #/` comments remove characters and the newlines inside them, so a
position taken from the stripped text would drift after any block comment. `SpValidate`
keeps a stripped→source offset map (`StripComments` fills it) and reports through it, so
detection is byte-identical to before — the same stripped text, the same verdicts — while
`Line`/`Column` land where an editor sees them. Pinned by the after-comment cases in
`TestDiagPositions`.

`KnownVariables` names what the **host** will supply at render time, mirroring the
reference's `ValidateOptions.knownVariables`: a reference to one is not "undefined", so the
`variable.undefined` warning is suppressed for it. Matching is case-insensitive. It only
ever silences a **warning** — an unresolved `%var%` has never made a template invalid and
must not start to, or a host rendering with runtime variables would see its own templates
called broken.

`SpExtractDirectives` returns `TSpDirectiveList` (`TList<TSpDirective>`): every `#set` /
`#def` / `#include` **occurrence** the renderer sees, in source order, duplicates kept, each
with `Kind`, `Name` (macro names lower-cased, include targets verbatim), `Value`, the
consumed line as `Text`, and the line's span in the original source under the same position
contract as `TSpDiag`. It is the editor-side companion to `SpExtract`, which answers *which*
names and targets a template uses and is deduplicated, unordered, valueless and unlocated —
everything a validator needs and nothing an editor can substitute, display or re-emit from.

The distinction is not cosmetic. Because the target list is deduplicated, one entry stands
for a target that appears both inside `/# … #/` and live, so a host expanding `#include` by
name expands the commented copy too; comments do not nest, so an included fragment carrying
its own comment then escapes the one it landed in. Reporting occurrences also keeps the
comment rule and the five line terminators in this unit rather than copied into every host.
The scan is the renderer's own — `StripComments` first, then the same directive parse and the
same include anchor (`MatchIncludeAt`, §5.1) that `SpExtract` and `SpValidate` run — so a
directive inside a comment, an inline `#include`, and an `#include` in a `#def` value (which
validate flags as `def.include-in-value`) are absent, present and reported-as-a-`def`
respectively, exactly as the renderer treats them. An `#include` whose whitespace ran across a
terminator is one occurrence whose span crosses source lines; everything else spans its line.
Pinned by `TestExtractDirectives` in `tests/local_tests.dpr`, whose comment cases were
confirmed to fail when the scan is pointed at the raw source instead of the stripped text.

Three limits on "the renderer sees", all three shared with `SpExtract` and `SpValidate`, none
of them specific to this function:

- **`#include` is resolved at RENDER time, not by this scan** (§5.2). What the list reports is
  "the line `SpExtract` and `SpValidate` call an include" — the same anchor the resolver runs
  on, so the three agree, but the occurrence list is an editing tool and never expands
  anything itself.
- **The scan reads the source as written; `SpRender` deletes reserved sentinels
  (U+E000–U+E005) first.** A raw one inside directive syntax makes the two disagree both ways:
  `#se<U+E000>t %x% = A` is no directive here and a `#set` to the renderer, and `/<U+E000>#`
  opens no comment here and one to the renderer. Measured on `@spintax/core`: its `extract` and
  `validate` diverge from its `render` in exactly the same two ways, so this is the family's
  contract for reserved characters in author markup, not a gap in this port. Three editor-side
  functions that agree with each other are worth more to a host than one that agrees with the
  renderer; sentinels reach a template through `SpNeutralize`, not through author markup.
- **Directives split on five line terminators, coordinates count three.** `NextLineBreak`
  ends a directive line on LF, CRLF, CR, U+2028 or U+2029, while `Line`/`Column` follow the
  editor EOL model of `TSpDiag` (LF, CRLF, CR). Two directives separated by U+2028 are
  therefore two occurrences on **one** line, the second at the column just past the
  separator — which is what an editor that does not break on U+2028 will draw.

Cost is one pass over the source for the whole document, not one per directive: the walk that
turns a stripped offset into line/column resumes from where the previous span left it
(`CursorLineCol`), which is why it shares its loop with `SourceLineCol` instead of copying it.
Rescanning from offset 1 each time — the first version of this — measured 628 ms for 400
directives at the END of a 124 KB document against 32 ms for the same 400 at its start, the
same document either way; it now costs 7.8 ms wherever they sit, steps 1.0 source characters
per document character with zero cursor restarts, and stays flat from 50 to 800 directives
where it used to run 63 → 881 ms. The shape of a benchmark, not its size, is what has to be
varied.

`SpExtract` and `SpValidate` were the expensive pair for a while — `SpExtract` 281 ms against
5 ms at 1600 directives — for reasons of their own: a body rebuilt line by line with
`s := s + line`, ordered-unique lists deduplicated by `TStringList.IndexOf`, and one
`SourceLineCol` walk from offset 1 per diagnostic. All three are O(document × items). They now
carry a dictionary for membership, scan each line where it lies instead of rebuilding one, and
resume the position walk (`AddDiagAtOrdered`). Measured at 6400 items in a document, 4× input
per step:

| | before | after |
|---|---|---|
| `SpExtract`, `#set`-heavy | 25 → 289 → 4704 ms | 0 → 0 → 15 ms |
| `SpExtract`, `%ref%`-heavy | 53 → 914 → 11 390 ms | 3 → 7 → 15 ms |
| `SpValidate`, `%ref%`-heavy | 88 → 1328 → 19 282 ms | 0 → 8 → 31 ms |
| `SpValidate`, `#set`-heavy | 41 → 609 → 10 375 ms | 19 → 320 → **4547 ms** |

The last row was still quadratic then, and it got its own differential on 2026-08-06 —
and then a second one, because the first round of work fixed the shape it was measured on
and left two others alone. What remained was the definition graph behind
`variable.self-reference` and `variable.circular-reference`, and it had **four** problems:

- every lookup was a linear `TStringList.IndexOf` — the name being resolved, the path
  membership test, whether a reference is a definition — and each visit re-parsed the
  value's references from scratch;
- the taint propagation was a fixpoint sweep, and on a chain each pass taints exactly one
  more name, so it ran once per definition over every definition;
- the cycle walk restarted at every definition. Remembering what a completed start had
  cleared fixed a chain with no cycle in it and **nothing else**: a converging graph still
  re-explored its shared subgraphs exponentially — 20 levels in a 914-byte document took
  89 ms, and every four more levels cost six times as much — and a document that is one
  big cycle was still walked once per definition;
- and with every definition reporting, `AddDiagAt` re-walked the document from offset 1 per
  diagnostic. That is the same resuming-cursor defect recorded above for `SpExtract`, in a
  fourth place.

Now: the graph is indexed once, the taint propagates along reverse edges from a worklist,
cycle reachability is computed once for the whole graph by an iterative colour walk
(iterative because a chain of definitions is as deep as it is long), and both diagnostic
loops take the resuming cursor.

| shape | before | after |
|---|---|---|
| 400 chained definitions | 23 959 ms | 8 ms |
| one cycle of 400 | 338 ms | 7 ms |
| one cycle of 6 400 | (hours) | 113 ms |
| converging DAG, 20 levels | 89 ms | <1 ms |
| converging DAG, 2 000 levels | (does not finish) | 71 ms |
| 6 400 flat definitions | 64 ms | 85 ms |

Those figures are **historical**, and the rows about cycles have now been overtaken twice.
They measure a walk that emitted one diagnostic per name; §5.3 replaced that with per-path
emission the next day, and the family reversed it back to per-name on 2026-08-18
(spintax-js#59), where the current costs live. What survived both turns is everything the
table's other rows measure: the indexed graph, the worklist taint, the resuming cursors, and
the reachability set — which is no longer a prune on a walk but the emitter itself.

The DESCENT predicate is still narrower than "is in a cycle": a name is walked when it can
REACH a cycle of length two or more, a direct self-loop being `self-reference` instead.
Verdicts were asserted, not argued — three differentials against the pre-rewrite build,
12 000 documents carrying 17, 1 944 and 2 856 circular-reference diagnostics, **0
differences**, against six control mutations giving 1 944, 817, 799, 860, 820 and 2 856.

**The lesson worth keeping is the benchmark's, not the algorithm's.** The first round
measured a chain with no cycle — the one shape its memo repaired — pronounced the result
linear, and wrote that into this file. A review found the two shapes that were not
measured. Before calling a cost linear, build the input that would make it not.

### An unterminated `/#` costs what the reference costs

Requiring the closing `#/` before consuming anything (§4) means a failed opener is rescanned
from the next character, exactly as a regex engine retries at the next position. On a
document densely packed with unterminated openers that is quadratic: `'/#a'` repeated to
12/24/37/49 KB costs 20/81/172/298 ms. The code it replaced was linear only because it
swallowed the rest of the document on the first opener.

`@spintax/core` on the identical input: 25/82/178/320 ms. So this is parity in cost as well
as in behaviour, and it is the family's shared weakness rather than this port's — but it is
written down here because nothing else says a `/#`-dense document is quadratic, and the
shape is cheap to construct by accident.

### 5.0 The `#set` / `#def` line, and the CR it takes with it

```
/^[ \t]*#(set|def)[ \t]+%(\w+)%[ \t]*=[ \t]*(.*?)[ \t]*\r?$/gmu
```

The tail is the part with the surprises, and both of them are in `[ \t]*\r?$`:

- the value is right-trimmed of **spaces and tabs only**. This port used PHP's `rtrim`
  charlist, which also eats `\0` and `\x0B`, so `#set %x% = A` + NUL rendered `A` here and
  `A\0` in the reference. Form feed was always kept by both;
- the optional `\r` is **inside the match** and **greedy**, so removing a directive line takes
  a trailing CR with it whenever `$` still holds *after* the CR. Under `/m` that is end of
  input or **any** line terminator, so the CR goes in five of six cases and survives only in
  front of an ordinary character:

  | `#set %x% = A` + CR + … | render |
  |---|---|
  | end of input | `` |
  | CR / LF / U+2028 / U+2029 | the follower, without the CR |
  | `Z` | `\rZ` — the CR stays |

Knock-on: a CR-shedding directive line contributes a bare terminator, so runs of them reach
the blank-run collapse (three or more `\n` become two) exactly as LF lines always did, and a
mixed run collapses only the part that became bare LFs.

**And the malformed-directive check is a different rule from this one.** `validate` reports
`set.malformed` / `def.malformed` from a scan that is not the regex above:

```js
for (const line of text.split('\n')) {
  const trimmed = line.replace(/^[ \t]+/, '')
  if ((trimmed.startsWith('#set ') || trimmed.startsWith('#def ')) && !DIRECTIVE_RE.test(trimmed))
    ...
}
```

Three things in four lines, and this port had two of them wrong until 2026-08-06 (both
reported valid templates as invalid — the §3 verdict divergence, not a message difference):

- the split is `'\n'` — **LF alone**, not the family's five terminators. A CR or a U+2028
  does not begin a line here, so `x<CR>#set broken` is one line beginning with `x`, is not a
  directive at all, and nothing is reported. This port split on all five;
- the left trim is `[ \t]` — **space and tab alone**. This port used PHP's `ltrim` charlist,
  which also eats NUL, VT, LF and CR, so `<VT>#set %x% = A` was trimmed into a directive
  shape it does not have;
- and `DIRECTIVE_RE` is `/gmu`, so `.test()` **searches** the trimmed line rather than
  matching it whole, and under `/m` its anchors break on the CR and paragraph separators that
  the split left inside. A malformed prefix followed by a CR and a well-formed directive
  satisfies the test, and nothing is reported.

The last one is not a hazard this port invented — it is what the reference does — but it is
the reason the scan cannot be written as "parse the line". `TryParseDirective` is tried on
each CR/U+2028/U+2029-delimited segment of the LF line, and one success clears the line.

This one took three attempts, and the first two are the point. The port left `\r\n` whole,
and the local suite pinned that with a comment claiming a measurement that was never taken
for the shape. Corrected in `v0.3.1` — as "CRLF only", written down here and in four other
places as an absolute, with a reason (*"`$` would have to hold after the CR, and it does
not"*) that is simply false. Review caught it the same day, against a corpus that varied the
CR's follower — the previous 720 cases had never made it a free variable. Measured: 699
cases, 210 render differences before, zero after.

### 5.1 The `#include` anchor, and what this engine does NOT do with it

One rule, one implementation (`MatchIncludeAt`), three callers — `SpExtract`, `SpValidate`,
`SpExtractDirectives`. It is the reference's, and the same rule the PHP core and the plugin
apply — though not the same spelling: both of those write `\s` under `/u`, where the reference
writes the class out:

```
/^[ \t]*#include[ \t\n\r\f\x0B]+"([^"]+)"[ \t\n\r\f\x0B]*$/gmu
```

The class is written out rather than left to `\s` on purpose: JavaScript's `\s` is
Unicode-aware and PHP's, under `/u`, is not, so an NBSP after `#include` is whitespace in one
and not the other. Writing the ASCII set keeps every engine on the same answer — and this port
must do the same, NBSP included. Put to the family as
[spintax-js#55](https://github.com/investblog/spintax-js/issues/55) and **settled on
2026-07-25 in favour of the ASCII class**, now pinned by corpus fixtures this port passes:
`#include<NBSP>"x"` is not an include, a space or a tab makes one, measured identical in both
engines.

Two consequences a line-by-line reading gets wrong, and this port did until 2026-07-25:

- the class holds `\n` and `\r`, so both gaps may **cross line terminators** — `#include` ⏎
  `"frag"` is one include everywhere in the family — and the target, being `[^"]+`, may cross
  them too;
- everything else on the line disqualifies it. `#include "a" junk`, `#include"a"`,
  `#include ""`, `#includes "a"` and `#include "a" "b"` are **plain text**, not includes.

A third consequence, and the one that is easy to miss: the scans must resume at the **match
end**, not at the next line start. The reference runs the rule with `/g`, so a match that
swallowed line starts leaves them behind — they are not `^` positions any more. Retrying them
invents includes, because the quotes can line up again from inside the previous target:

```
#include "a          one include in the family, target `a` + LF + `#include `;
#include "           scanning every line start finds a second one, `   ` + LF + `b`,
b"                   and with a slug list that is a verdict.
```

That second half is not cosmetic: `include.unknown-target` is an **error**, so a loose anchor
calls valid templates invalid — a verdict divergence, which §3 lists as REQUIRED parity.
The corpus cannot see it (two plain `#include` cases), so the gate is
`TestIncludeAnchor` in `tests/local_tests.dpr` plus the differential recorded in the commit:
86 419 include-shaped inputs answered by `@spintax/core`, 18 487 include-list and 15 758
verdict differences before the fix, zero after.

### 5.2 Resolution: `TSpContext.IncludeResolver`

Since `v0.3.0` the engine resolves includes, the way the family does ([ADR
0004](decisions/0004-include-resolver-seam.md)). `TSpContext.IncludeResolver` is a
`TSpIncludeResolver` the host subclasses — an abstract class, caller-owned, shaped like the
`TSpRng` seam. The engine owns the semantics; the host owns the lookup. `nil` (the default)
leaves every `#include` line in the output verbatim, which is also what the reference does
with no resolver, so the pre-`v0.3.0` behaviour is unchanged for every existing caller.

The semantics are not what splicing raw text into the document would give — this is the part
a host gets wrong, and the reason the seam exists at all:

- the child is parsed and rendered **on its own**, and its **output** is substituted, so a
  `{`, `|` or `%` the child produced is never re-parsed by the parent;
- the child inherits the **runtime context** and the RNG instance, but **not** the parent's
  `#set`/`#def` — it builds its own from its own source (the plugin's `for_child_render`);
- a child is author markup, so the reserved-sentinel strip runs on it: a neutralized value
  embedded in a template is **removed**, not restored. Neutralized data belongs in the
  runtime context (§6);
- an unknown target, a cycle, or a stack already `MaxIncludeDepth` deep resolves to the
  **empty string**, leniently — there is deliberately no error for it, and `validate`
  deliberately does not call a circular include invalid;
- cycles are keyed on the ref **string**, so two aliases of one template are not a cycle and
  unwind until the depth cap;
- `MaxIncludeDepth` counts the include stack **only** — parse nesting and variable expansion
  have their own limits. `0` selects `SP_DEFAULT_INCLUDE_DEPTH = 20`, and so does any
  negative value — a zeroed record field cannot be distinguished from a deliberate `0`, so
  this field cannot carry the reference's "`0` resolves nothing"; leave the resolver `nil`
  for that.

Resolution runs at the end of a document's render and **before** the cosmetic pipeline, which
is the reference's order: the post-process and the mandatory safety restore each run **once**,
over the assembled document, so the cosmetic passes see across the seam and a sentinel a child
emitted is restored at the top. A child therefore never goes through `SpRender` itself.

The corpus has no field for any of this. The gate is a differential against `@spintax/core`
with a matching resolver on both sides — 52 cases, **48 of which differ when the seam is left
nil**, zero when it is not — plus `TestIncludeResolver` in `tests/local_tests.dpr`.

### 5.3 Definitions are a map, and the cycle count WAS the walk's

`extractDirectives` returns `setDefs`/`defDefs` as **Maps**, so a name defined twice keeps
the **last** value, and everything downstream reads that map: the self-reference test, the
cycle walk, and the plural taint. This port kept every occurrence and resolved a name to the
**first**, which diverged in both directions at once — inventing diagnostics the reference
does not give and missing ones it does:

| template (one directive per line) | reference | this port, before 2026-08-06 |
|---|---|---|
| `#set %x% = %x%` / `#set %x% = B` | — | `variable.self-reference` |
| `#set %a% = plain` / `#set %a% = %b%` / `#set %b% = %a%` | two `circular-reference` | — |
| `#def %n% = plain` / `#set %n% = {a|b}` / `#set %n% = plain` / `{plural %n%:…}` | — | `plural.count-macro` |

The **count** was a separate contract, and a harder one, because it was a property of the
walk rather than of the graph. The reference's `detectCycle` did not deduplicate references
and its `return` left only the current frame, so `#set %a% = %b% %b%` with `#set %b% = %a%`
gave **three** `variable.circular-reference` diagnostics where the graph has two names. This
port reproduced that walk exactly, on 2026-08-07, rather than reasoning about which names are
in a cycle — because no reasoning about the graph reproduces a number that belongs to the
traversal.

**The family reversed it on 2026-08-18** (`@spintax/core` 0.6.0, `spintax/core` 0.8.0, the
plugin mirror, [spintax-js#59](https://github.com/investblog/spintax-js/issues/59)): **one
diagnostic per NAME that takes part in, or leads to, a cycle.** The reason is the shape below,
and it is not a preference: the number of ROUTES through a converging graph is exponential in
its depth, and re-walking every route *is* the emission, so per-path could not be kept and
bounded. 547 bytes took the live `/validate-template` out with HTTP 503.

This port emitted per path for eleven days. The set of names never differed — `MarkCyclic`
already computed exactly the per-name predicate as a prune — so the change deletes the walk
and emits from the set it was pruned by. Measured here:

| shape | per path (through `v0.7.0`) | per name |
|---|---|---|
| `#set %a% = %b% %b%` + `#set %b% = %a%` | 3 diagnostics | **2** |
| converging diamond, 20 levels, 507 bytes (the corpus fixture) | 2 097 152 diagnostics in 7 949 ms | **22 in about 1 ms** |
| one cycle of 6 400 | 975 ms | **113 ms** |
| one cycle of 25 600 | 18 775 ms | **503 ms** |
| one cycle of 51 200 | 82 222 ms | **2 071 ms** |

The last three rows are the quadratic going away with the walk: a cycle of N used to be N
diagnostics each found by an N-step descent. What is left grows a little faster than the
document — 17.7, 19.6 and 40 µs per name across the last three rows — and is **deliberately
not diagnosed further**, because it is 40× cheaper at the largest size measured and nothing
in it is a bound that fails to hold.

The diamond row is the one that matters: the corpus carries that shape as
`validate/cycle-diamond-terminates`, and it **cannot** gate the count, because expected
diagnostics are matched as a subset — it gates only that the engine answers. That is exactly
what let per-path emission hide for eleven days, and it is why the count is pinned in
`TestGraphStress` here, as each engine was asked to pin its own. The two canaries that pinned
the old numbers were rewritten **in place, with the reversal in the comment**, rather than
silently corrected.

Verified against `@spintax/core` 0.6.0 by differential: **800 generated definition graphs** —
cycles, converging diamonds, self-loops, duplicate names, dangling references and repeated
references — **0 differences**, against a control of **91** on the `v0.7.0` tree.

The message text and the eight-name route cap the reference added with this change do not
reach this port: `TSpDiag` carries a code, a severity and positions, and no message.

**One thing worth keeping on the record.** The last line of this section, before the reversal,
read: *"the only honest fix would be a family decision to cap or deduplicate the diagnostics."*
That is what the family did. The measurement that made per-path look mandatory — the corpus
compares the multiset of codes — was true, and the conclusion drawn from it was still
temporary.

### 5.4 What makes a permutation `<config>`

`[<sep=", " maxsize=2>a|b|c]` — the leading `<…>` element is lifted out as configuration
rather than rendered. Two independent tests decide it, and `v0.3.3` fixed the outer one:
a leading `<li …>` stays content (the HTML-start-tag guard), and a real key must be present
(`\b(?:minsize|maxsize|sep|lastsep)\s*=`). What `v0.3.3` did not touch is the extractors
that then read the values — three more regexes:

```js
const MINSIZE_RE = /minsize\s*=\s*(\d+)/i;
const MAXSIZE_RE = /maxsize\s*=\s*(\d+)/i;
const SEP_RE     = /(?<!last)sep\s*=\s*"([^"]*)"/i;   // the lookbehind excludes `lastsep`
const LASTSEP_RE = /lastsep\s*=\s*"([^"]*)"/i;
```

**The gate has the word boundary and the extractors do not.** `CONFIG_KEY_RE` is
`/\b(?:minsize|maxsize|sep|lastsep)\s*=/i`; none of the four above carries a `\b` at all. So
one unglued key opens the door and a glued-on one then walks through it: in
`[<sep="-" xmaxsize=1>a|b|c]` the `sep=` satisfies the gate and `xmaxsize=1` is then read as
`maxsize`, giving one element. Measured over 200 seeds in both engines on 2026-08-06 — the
reference yields exactly the three single elements, and so does this port. Remove the real
key and the boundary matters again: `[<xmaxsize=1>a|b]` has no config at all and renders
`Axmaxsize=1b`, the whole string being the single-separator form.

Being regexes, they have three further properties a hand-written scan does not get for free,
and this port was missing all three until 2026-08-06:

- **the `=` is required.** With it optional, `[<sep="-" maxsize 2>a|b|c]` parsed as
  `maxsize=2` and rendered a random two of the three where the reference renders all three —
  a render divergence, reachable because the outer gate had already been satisfied by the
  real `sep=`;
- **`\s` is the full ASCII set**, VT and FF included, not `[ \t]` — the same narrowing the
  `v0.3.3` review found in the gate, one layer down;
- **a failed candidate is retried at the next position.** `[<sep=x sep="-">a|b]` finds the
  unquoted `sep=x`, fails, and goes on to the quoted one; this port stopped at the first.
  The quotes are likewise required to close, so `[<sep="X>a|b]` configures nothing.

3 000 generated permutation documents against the reference, canonicalised for RNG (§3
makes selection order a non-goal): **0 differences**, against controls of 94 (`=` optional)
and 814 (narrow whitespace). The glued-key forms are pinned by `TestPermConfigExtractors`
instead — a generator that varies a config string rarely spells `xmaxsize=`.

### 5.5 `plural.locale-missing`: a warning where validate used to be silent

Adopted 2026-08-18 from [`spintax-js#65`](https://github.com/investblog/spintax-js/issues/65),
where a pipeline rendering ~1000 articles per campaign shipped unresolved plural blocks into
finished pages, and filed against this engine as issue #1.

`SpValidate` files **no arity verdict when no locale normalizes** — deliberately, and that
half stands: the template may be right for the locale the host will actually render with, and
failing a good template for a fact the caller never claimed is worse than silence. The
renderer has no such choice. It resolves against `PluralArity('')` = 2 whatever the caller
said, so a block of any other form count comes out as the fullwidth-brace fallback
(U+FF5B/U+FF5D) — invisible to any downstream check that scans for ASCII braces.

So the seam is a **warning**, which by definition does not move the verdict:

| shape | no locale | `ru` | `en` |
|---|---|---|---|
| 3 forms | `plural.locale-missing` / warning, still **valid** | silent | `plural.arity` / error |
| 2 forms | silent — the default resolves it | `plural.arity` / error | silent |

All six cells measured on the reference, 2026-08-18; supplying any locale replaces the
warning with the real verdict, in both directions.

A non-empty locale that normalizes to nothing (`_en`) is no locale at all, here as in the
arity check, and a structurally broken block still reports only `plural.nested-brackets` — the
new check inherits that branch's `Continue` rather than inventing a second problem. The
default arity is asked of the same table the renderer uses rather than written as `2`: the
validator and the renderer disagreeing about that number is the whole of the bug.

**The qualification this section shipped with is now closed, by the family.** The form count
the validator used was the pipes it could SEE, while the renderer counts them after expanding
`%variables%` — so a form list grown or shrunk by a reference was judged on the wrong number,
in both directions. Measured here on 2026-08-18, reported upstream, fixed in all five engines
the next day as [`spintax-js#66`](https://github.com/investblog/spintax-js/issues/66):

| template | validate, before | validate, now | render |
|---|---|---|---|
| `#def %tail% = few\|many` + `{plural 2: one\|%tail%}` | silent | `plural.locale-missing` | fullwidth fallback |
| `#def %forms% = one\|many` + `{plural 2: %forms%}` | `plural.locale-missing` | silent | resolves fine |

Both rows now agree with what the engine does with the same template, which is the whole
point; under `locale=ru` the first row was a `plural.arity` **error** on a template that
renders correctly. The two checks that pinned the old answers were written so that a family
fix would surface here as a failure rather than as silence, and that is exactly how this
arrived.

`ExpandFormsForCounting` substitutes definition values into the form list and splits the
result — every reference per pass, as the renderer's expansion does, for at most 51 passes
**and at most 65 536 UTF-16 code units of GROWTH**. Passes alone do not bound the work:
`#set %a% = %b% %b%` over `#set %b% = %a% %a%` doubles the text every pass, so 51 of them is
2^51, and that 62-character template took `validate()` out with an out-of-memory crash in
**every** engine of the family, this one included — it reached the corpus while this port was
being caught up, as two new fixtures, one with a cycle to catch it and one without. The walk
over the `#set` chain was built iterative here from the start, which is the other half of the
same upstream fix; a 9000-link chain is pinned locally because the reference's recursive walk
threw at exactly that size.

The budget decides a verdict, so each of the following is one — and this port got all three
wrong once before getting them right. Two were Codex-review findings here; the third was
upstream's own review, which landed while this section was being written.

**It bounds GROWTH, not total length.** A form list of 65 KB of ordinary text is plainly two
forms and must keep earning `plural.arity` under `ru`. This port took the ceiling from
upstream's work in progress, where it was still a cap on total length, and carried that
regression for the length of one review round; no corpus fixture covers it. The budget is now
`Utf16Len(formsRaw) + 65 536` — expansion that ADDS this much is a graph exploding, while a
long form list is just long.

**It is counted in UTF-16 code units, not bytes.** Exceeding it suppresses `plural.arity`, so
the budget is a verdict, and under FPC `Length` is bytes: 40 000 Cyrillic characters are
80 KB and 40 000 units, so a byte count left this port silent where the reference reports the
error. `Utf16Len` counts what the reference's `.length` counts — every non-continuation byte
is one unit, an astral lead is two — and under a UTF-16 compiler it is `Length` itself. The
comment that used to sit on the constant called the difference "a safety bound rather than a
verdict"; it was neither safe nor a non-verdict.

**And it is enforced DURING a pass, because one pass can explode before anything is
measured.** `#set %a%` holding 20 000 references to `%b%`, and `%b%` holding 5 000 to
`%c%`, is 60 KB after pass one — within budget, so the walk continues — and pass two asks
for 20 000 × 5 000 references: **300 MB out of a 75 KB template**, acyclic, so the cycle
detector never sees it. Measured at 3.5 s here, and on a 32-bit build the next size up is an
out-of-memory crash rather than a slow answer. The pass is therefore built by hand, counting
units as it goes and stopping at the budget. 3.5 s → 35 ms. Upstream found and fixed the same
thing the same day, independently.

**Only where the count is provably invariant.** A value carrying any bracket suppresses the
count-based verdicts rather than guessing: `{a|b}` really does always freeze to one form, but
the false branch of `{?flag?a|b|c}` freezes as `b|c`, which is two, and the two cannot be told
apart without evaluating the construct. Predicting the roll was tried first upstream and
produced a fresh crop of false errors. Construct-free is a **sufficient** condition,
deliberately not a necessary one. A name the host declares (`KnownVariables`), a reference the
template does not define, and a chain past the budget suppress it too — the same retreat
`plural.locale-missing` is built on: no verdict on a fact the caller never claimed.

One case is not a prediction. A `#set` named **directly** in the form slot is substituted
verbatim and is still spintax when the plural is decided, so its brackets keep earning
`plural.nested-brackets` — and "direct" is a property of the PATH, not of one hop: `%a%` →
`%b%` never crosses a `#def`, so the macro text arrives whole. Through a `#def` it is rolled
first and earns nothing. A stray closing bracket counts as much as an opener, because
`CheckBrackets` stays quiet when it balances against an opener elsewhere while every
renderer's plural guard rejects all four.

Two things here no fixture can express, so `TestPluralFormCounting` carries them: the corpus
schema has no `knownVariables` field, and nothing in it distinguishes **which** of two
definitions of one name survives — the maps keep the LAST, and that is the difference between
a verdict and none.

**What it costs, with the control run.** Expanding a form list is real work where the raw
count was a pipe scan, so it was measured against the same documents on the previous commit,
not asserted (2000 plural blocks each, 2026-08-18):

| document | before | after |
|---|---|---|
| plain `a\|b\|c` blocks, no reference | 6 ms | 5 ms |
| one `#def` holding a form list, named by every block | 8 ms | 4 ms |
| a 20-link `#set` chain named by every block | 8 ms | 5 ms |
| 2000 **distinct** slots over that chain | 38 ms | 156 ms |

The count is memoized on the raw form slot, because the answer depends on nothing else once
the document's definitions are read — and naming one `#def` from every block is exactly what
a form list held in a definition is FOR, so that is the shape to make cheap. Per block it
measured 140 ms against 5 ms on the third row. The last row is the honest worst case, where
no two blocks share a slot and the cache never hits: linear in blocks × chain length, 4× the
raw scan it replaced, on a document no generator has a reason to emit. The reference pays the
same shape (its own pass loop is 51 replaces over the slot) about 2× faster in constant terms
— §3 does not ask performance to match.

**What the corpus can and cannot say.** `validate/plural-no-locale-arity-mismatch-warns`
pins that the warning is emitted; expected diagnostics are matched as a **subset**, so the
mirror rule — a 2-form block staying silent — is not expressible there. That half, and the
locale/verdict table above, live in `TestPluralLocaleMissing` in `tests/local_tests.dpr`,
measured case for case against `@spintax/core` 0.4.0. Four of its 18 checks assert the
RENDER side, because the warning's claim is about what rendering does and would otherwise go
on being emitted after a render change had made it false.

**It cost a position walk.** All four plural diagnostics anchor at their block's `{plural `
and are emitted in source order, but each went through the mapper that rescans from offset 1,
which is O(document × blocks) — the sixth site of the defect AGENTS.md names. Latent while
the no-locale path raised nothing; the warning gives it one per block. Measured on 2000
3-form blocks in 102 KB: **1460 ms**, and the same document under `locale=en` (the
`plural.arity` path, which has had this shape since it was written) **1705 ms**. With a
resumed cursor, **10 ms** each.

The loop keeps **two** cursors, and that was a Codex-review finding on the first attempt,
which shared one. A resumed walk is cheap only while its offsets never go backwards: blocks
arrive in source order, but a single block can raise `plural.count-macro` **and** one of the
others at the same anchor, and the second call then asks for an offset the cursor has already
passed, so `CursorLineCol` restarts from 1. Answers stay correct; the cost comes back. 2000
blocks raising both measured **523 ms** through one cursor and **11 ms** through two. Each is
monotonic on its own — `count-macro` fires at most once per block, and nested-brackets /
arity / locale-missing are mutually exclusive. `TestPluralLocaleMissing` pins that shape's
COORDINATES and nothing else: the single-cursor version answered them correctly too, since a
cursor asked for an offset it has passed restarts rather than lying. Only this measurement
separates the two, which is why it is written down here.

### 5.6 A conditional in the count slot, resolved before the numeric test

Adopted 2026-08-18 from [`spintax-js#67`](https://github.com/investblog/spintax-js/issues/67).

```
#set %flag% =
#set %n% = {?flag?1|2}
start {plural %n%: one|two} end
```

rendered `start  end` here and in the TS reference — no fallback braces, no diagnostic,
`SpValidate` returning nothing. Both PHP engines have always rendered `start two end`: they
run the conditional stage over the whole document **before** plurals, so a plain number
reaches the slot. This engine expanded `%variables%` into the raw slot and left constructs
literal, so the conditional survived, failed the numeric test, and the block was **erased**.
`plural.count-macro` exempts conditionals *because* they resolve before plurals — the
validator was written to a renderer behaviour nobody had implemented.

`ResolveCountConditionals` runs over the var-expanded count slot, before every check, which
is what makes the lenient fallback's text comparable across engines: it prints the count as
the plural stage saw it, resolved.

**The branch is substituted, never rendered.** Enumerations and permutations resolve AFTER
plurals, so a branch yielding `{a|b}` still reaches the numeric test intact and still erases
the block, exactly as the plugin does; rendering it would spin it to `a` and invent a count
no engine has. Four of the eight corpus fixtures are negative controls for precisely this —
an enum in the count slot still erases, a branch resolving to text still erases, a resolved
branch with text beside it still erases, because the slot is tested whole.

The **form** slot is deliberately untouched. There the engines genuinely disagree, and
picking a side is not a bug fix; `ExpandFormsForCounting` declines to judge a form list whose
macro chain carries a conditional for the same reason (§5.5).

**Iterative over spans, and that is a cost decision, not a style one.** The taken branch is a
SPAN of the source, never a copy, and the untaken one is skipped, so the pass never copies a
branch out. Recursing into the branch would die on deep input — the reference measured a
`RangeError` at ~9000 levels, and `SpRender` must not fail on content. Searching for the
matching brace per `{?` would be quadratic, and an **unbalanced count slot is legal input**:
only the whole `{plural …}` block has to balance, and the slot is cut at the first `:`.
`MatchBraces` pairs every brace in one pass instead. Measured here: 40 000 unmatched openers,
**1 ms**; 20 000 nested conditionals whose branch is NOT taken, **6 ms**.

**Deeply nested conditionals whose branch IS taken are quadratic, and this section first
claimed otherwise.** `RecognizeConditional` finds the separator by scanning the body, so N
nested truthy conditionals scan N + (N−1) + … characters. Measured 2026-08-18: 2000 levels
**54 ms**, 4000 **210 ms**, 8000 **913 ms** — four times the cost for twice the depth. The
first version of this text said "every character is visited at most once" and quoted only the
6 ms above; that measurement was taken with the flag EMPTY, so the else branch was a handful
of characters and the nested traversal never ran. A claim about a cost, measured on the one
shape that cannot exhibit it — the same defect this port has recorded before, in the
sentence right above the code that had it.

The cost is the family's, not this port's: the reference scans the body per level too, and is
slower — 2000 levels **393 ms**, 4000 **1426 ms**, 8000 **4510 ms**, measured the same day.
Upstream's own commit for #67 says deep balanced nesting stays super-linear in every engine
and that bounding input is a host job (§9.3); the reference deployment caps a template at
8192 characters. So it is recorded here rather than fixed: an exact fast version needs the
separator scan's clamped, type-agnostic bracket counter precomputed, and a second reading of
that rule is what the ONE-recognizer discipline below exists to prevent. `TestPluralFormCounting`
now carries BOTH branches at a size the suite can afford, so the shape cannot go unmeasured
again.

The conditional grammar stays in ONE recognizer. `RecognizeConditional` reports offsets and
`TryParseConditional` materializes the branches from them; a second copy of those rules is
how the family's #55–#57 syntax divergences happened.

### 5.7 Conditional truthiness is decided over the FULL whitespace class

`{?…}` truthiness is named in §3 as parity-REQUIRED. Every other engine in the family
decides it with `/\S/u` — the TypeScript reference, both PHP engines (`is_truthy` is
`preg_match('/\S/u', …)`) and the Python port, which writes the class out as `JS_SPACE`
rather than trust Python's Unicode `\s`. This port tested six ASCII characters, **byte by
byte**, so a variable holding one U+00A0 was truthy here and falsy everywhere else, and the
other branch rendered.

Fixed 2026-08-18: `IsJsSpaceCp` enumerates JavaScript's `\s` — `\t \n \v \f \r`, space,
U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF — and
`ConditionalTakesThen` walks the value as CODE POINTS through `SpCodePointAt`. A byte scan
sees NBSP as `$C2 $A0`, neither of which is an ASCII space, which is exactly how the
divergence survived. The ASCII half of the class is unchanged, so nothing that passed before
moves.

The class is enumerated, not taken from the RTL, for the reason the Unicode tables are
baked: the answer must not depend on which Unicode version the host compiler shipped. U+200B,
U+0085 and U+3164 are deliberately **outside** it — all three are non-space to the reference
and make a variable truthy, and they are in `TestConditionalTruthiness` as the controls that
stop the class drifting into "anything non-ASCII".

**Why nothing caught it.** No corpus fixture carries a Unicode space, and neither did any of
the 500 local checks. It surfaced when a Codex review of the §5.6 work noticed the count slot
had given the predicate a second caller. The nearest thing to a justification for leaving it
was a line in the agent charter calling the ASCII narrowing a family convention — true of the
`#include` anchor, where the reference writes out `[ \t\n\r\f\x0B]` itself, and false here.
A wrong justification is worse than wrong code, so that line now says which site it means.

U+2028 and U+2029 are in the class but never reach a `#set` value: they end the directive
line in both engines, so the value is empty and the separator survives as text. Both are
pinned, along with a `…\u2028x` case that tells the two readings apart — the first
measurement of them here was taken through a JavaScript `trim()` that ate the separator, and
the wrong expectation reached the test file before the suite rejected it.

**Measured by differential**, not only by cases: 6000 generated templates of definitions and
plural blocks, the corpus generated ONCE and fed to both engines, Unicode spaces and their
two non-space controls in the value pool. Zero validate differences and zero render
differences (12 cases whose reference output moves between six seeds are skipped —
selection is a §3 non-goal). The same harness against the previous commit reports 2328 and
931 differences, which is the control run that makes the zero mean something.

### 5.8 The render-side expansion bomb, and a budget on what expansion inserts

Adopted 2026-08-18 from [`spintax-js#69`](https://github.com/investblog/spintax-js/issues/69),
the render-side twin of the counting bomb in §5.5. Sixty-two characters:

```
#set %a% = %b% %b%
#set %b% = %a% %a%
%a%
```

Every expansion replaces one reference with two, so the text doubles and `MAX_VARIABLE_DEPTH`
of 50 permits 2^50. The cycle guard never fires: an acyclic chain of doubling definitions does
the same thing. Measured on this engine before the fix — a plural naming `%a%` in its forms
**aborted with `EOutOfMemory`**, an exception escaping `SpRender`, which §9.2 says never
happens on content; a bare reference and one inside a permutation **ran past 60 s**. Live in
every engine of the family, and old — the issue confirms it against published `@spintax/core`
0.3.4, so it predates this week's work.

It is not a construct that is unsafe. `plain text` and `{?a?…}` are fine — a conditional reads
truthiness and never expands the value — while `%a%`, `[%a%|z]` and either plural slot all
reach it. The unsafe thing is **any reference whose value gets expanded**, which is the
general variable-resolution path.

`SP_RENDER_EXPANSION_BUDGET` is what expansion may INSERT over one `SpRender` call, children
of an `#include` included: one budget per call, not per document, or the include depth would
multiply it. It is charged per substitution and checked **before** the substitution happens,
because one substitution can be the whole explosion — the same lesson §5.5 records for the
counting path. Both sites are charged: `ResolveVariable` (the general path) and
`ExpandVarsOnly` (the plural slots).

**When the budget is gone, the reference is left LITERAL.** That is already what this engine
emits for a name it does not know, so no new output shape enters the language: a plural whose
count did not resolve erases exactly as it always has, and a host gets text instead of a
crash. Measured after: every shape answers in under 350 ms, the bomb producing ~600 KB of
half-expanded text ending in literal `%a%` / `%b%`.

**The truncated output is deliberately NOT parity-gated**, and the constant is settled at
1 MB — the family fixed both in `@spintax/core` 0.5.2 while this was being written. The
conformance README states it: the engines expand by different mechanisms, a per-reference tree
walk here and in the reference against a whole-text fixpoint in both PHP engines, so they stop
in different places and produce different byte counts for the same bomb. Making those agree
would mean rewriting one engine's traversal for input no author writes. **The contract is that
render terminates, stays lenient, and leaves what it could not afford as a literal `%name%`**;
each engine pins its own bound in its own suite.

**A value carrying no construct is not charged at all.** It is substituted and never expanded
again, so it cannot be part of an explosion — and charging it truncated ordinary output: a
plain 100 KB `#set` referenced twenty times, and ten `#def` hops over one literal, which is
100 KB of finished text with no recursion in it. The first cut of this budget charged before
that check and got both wrong; the reference orders them the other way. Measured after,
byte-for-byte against `@spintax/core` 0.5.2: **2 048 021** and **102 402** characters, no
reference left literal in either.

That ordering, plus refusing on an EMPTY purse rather than on one the next substitution would
overdraw, puts this engine at the same stopping point as the reference on the bomb itself
— 1 198 225 characters for `%a%`, to the byte. Worth knowing, and not a contract: the
README's own measurement of the spread across engines is 1 198 223 against 599 191.

`TestRenderExpansionBudget` asserts the CONTRACT, plus this engine's own bound: every shape
from the issue's table answers, a refused reference stays literal, an unresolved count still
erases, a plain value is never charged, and the budget is **per render**, not cumulative, so
the second render of a compiled template matches the first — the shape this could most easily
have got wrong, since a host renders a compiled template in a loop and a carried-over counter
would leave only the first render correct.

One purse covers the whole call, `#include` children and all. A budget created per child
document bounds each subtree and bounds nothing overall: the reference shipped exactly that in
0.5.2 and fixed it in **0.5.3** — fifty include lines over one 62-character body turned 690
bytes into **57 MB**, growing linearly with the include count. This port shared the purse from
the first cut, so 0.5.3 needed no change here; the check exists because a review pointed out
that nothing else in the suite would have noticed a child resetting the counter, and it was
confirmed by building an engine that does reset it, where that check fails and nothing else in
the file does. Measured flat: 1, 50, 200 and 500 include lines over the same body give
1 198 225 / 1 198 519 / 1 199 419 / 1 201 219 characters, the growth being the include lines'
own text.

**Where this engine sits, measured 2026-08-18** against `@spintax/core` 0.5.3, now that the
family's remaining question is volume and time rather than survival:

| shape | this port | reference |
|---|---|---|
| `#set` bomb, `%a%` | 448 ms, 1 198 225 chars | 104 ms, 1 198 225 chars |
| `#def` bomb | 872 ms, 3 353 865 chars | 161 ms, 3 353 865 chars |
| 200 `#include` lines over one bomb | 464 ms, 1 199 419 chars | ~210 ms, ~1.14 MB |

The volume is **identical to the byte** on every shape the two engines share, which is worth
recording precisely because the corpus deliberately does not assert it. The time is 3–5× the
reference and roughly a sixth of the Python port's, which the family measured at ~5 s for the
same budget. It is linear in output, not super-linear — a terminating doubling chain costs
**~1.2 ms per KB** flat from 32 KB to 190 KB — so the constant is allocation and copying, where
a JavaScript engine has ropes and this one has strings. §3 does not ask performance to match,
and nothing here is a bound that fails to hold.

## 6. Trust model

`SpNeutralize` is a utility the **host** applies to data-derived (T2) input. The engine
must NOT auto-shield author-controlled (T1) values. Sentinels U+E000–E005 are the engine's
reserved range; the safety restore is **mandatory** and survives `PostProcess=False`.

## 7. Port hazards specific to Object Pascal

1. **`{$mode delphi}` is the contract.** Anything needing `{$mode objfpc}` or FPC-only RTL
   is a portability break even with a green corpus. The directive itself must stay wrapped
   in `{$IFDEF FPC}` — a Delphi-lineage compiler rejects `{$MODE}` as invalid.
2. **`string` is a byte string here — and that is currently load-bearing.** FPC's default
   `string` is not UTF-16. The corpus is full of Cyrillic and Unicode punctuation, so
   byte-indexing a multi-byte character is the first bug class to suspect in any new string
   handling. Existing helpers (`IsAsciiWord`, `LowerAscii`) are ASCII-scoped **on purpose**.

   The structural scan is safe under either width (it branches only on ASCII). The sentinel
   and fullwidth-brace literals are **not** — they encode specific code points, so they
   branch on `UNICODE` and must stay that way. Verified on both compilers; see
   [decisions/0003](decisions/0003-delphi-compatibility-audit.md) and
   [tests/delphi/RESULTS.md](../tests/delphi/RESULTS.md).

   **Anything new that spells a specific non-ASCII code point needs the same treatment.**
   Writing its UTF-8 bytes is not portable: on a UTF-16 compiler those bytes are decoded
   through the machine's ANSI codepage, so the result varies by machine. That was a real
   defect here, and it broke the mandatory safety restore silently.
3. **Warnings must be fatal** (`-Sew -vm4046`) — FPC accepts an uninitialised function
   result or a shadowed variable with a mere warning, and those are what a port produces.
   `-vm4046` masks one warning raised by FPC's own generics RTL and nothing else.
4. **A host may build with overflow and range checks on; FPC's default build does not.**
   Arithmetic that wraps on purpose — the mulberry32 mixer — raises `EIntOverflow` under
   checks and passes silently without them. Suppress checks around such code with `$IFOPT`,
   so a host that wants them keeps them everywhere else. `build.sh` compiles the local
   suite a second time with `-Co -Cr`, which is what catches this.
5. **The reference does not use one regex flag set.** `EMAIL_RE`, `DOMAIN_RE`,
   `SINGLE_ABBR_RE` and `CAP_AFTER_BLOCK_RE` carry `/giu/`; the rest are `/gu/` or `/u/`.
   Under `/iu` a property escape is CASE-FOLDED: Ll gains 1446 code points (32 with a
   differing uppercase) and L gains U+0345. Use `SpIsUniLowerFolded` /
   `SpIsUniLetterFolded` for those rules and the strict predicates everywhere else.
   Check the flags before porting any regex; this was caught in review, not by the corpus.
6. **Unbounded nesting must be iterative.** A recursive walk dies on deep input the
   reference handles — the lesson the Python port already paid for. `ParseSequence` /
   `RenderNodes` are the places to watch.

## 8. Verification method

The corpus is the acceptance suite; local reasoning is not evidence. Two rules carried
over from the sibling ports:

- **Never write an expectation by reading this port.** Measure the reference
  (`@spintax/core`) instead. Reading the port produced 18 wrong expectations in `spintax-py`.
- **The corpus schema cannot cover everything.** `#include`, permutation `<config>`, plural
  lenient fallbacks, and the parsed-AST input path have no fixture field. Every real bug in
  the sibling ports lived on those surfaces. They need local tests measured against the
  reference — never asserted from the port's own behavior.
- **The harness is part of the measurement.** FPC's `fpjson` does not decode a JSON
  code-point escape faithfully: it DROPS a `\u0000` on every accessor and turns every escape
  above ASCII into a question mark, because the scanner converts through the system codepage
  (measured on FPC 3.2.2, 2026-08-06). The corpus's first NUL-bearing fixture arrived at the
  engine as `#set broken`, and the engine's correct answer was reported as a failure.
  `SpxJson` now decodes those escapes itself before fpjson sees them; a NUL travels as
  U+0001, the only kind of character fpjson delivers intact, and a file carrying one of its
  own is refused rather than rewritten. The second half was latent — the fixtures spell
  non-ASCII as raw UTF-8 today — and would have compared a future escaped fixture against a
  row of question marks. **Before believing a green run, check that the input reached the
  engine**: the probe that found this printed the template's bytes, and the fix was only
  trusted once a mutated engine made the same fixture fail.

## 9. Open questions

Tracked in [`TODO.md`](TODO.md). Nothing here blocks use of the engine as it stands.
