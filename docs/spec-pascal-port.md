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
(234 cases total, 2026-08-07 — the corpus grew that day with the cases the family pinned
from this port's divergences):

| fixture file | cases | passing |
|---|---|---|
| render-semantics | 72 | 72 |
| validate | 54 | 54 |
| render-postprocess | 43 | 43 |
| render-deterministic | 16 | 16 |
| comments | 13 | 13 |
| extract | 12 | 12 |
| neutralize | 10 | 10 |
| render-rng-selection | 10 | 10 |
| render-rng | 4 | — skipped by design (within-engine reproducibility only) |

**`PASS=230 FAIL=0 SKIP=4`** — the whole corpus, the 4 skips being `kind:rng` render
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
  payload rather than prose renders with `PostProcess=False`. Whether the family SHOULD
  exempt neutralized spans is an open question in `docs/TODO.md`.

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

Those figures are **historical**, and the rows about cycles no longer describe this engine:
they measure a walk that emitted one diagnostic per name, which is not what the reference
emits. §5.3 replaced the emission rule the next day and the cost moved with it — see the
table there. What survived unchanged is everything the table's other rows measure: the
indexed graph, the worklist taint, the resuming cursors, and the reachability set, which is
now the walk's prune rather than the walk itself.

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

Three things in four lines, and this port had two of them wrong until 2026-08-07 (both
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

### 5.3 Definitions are a map, and the cycle count is the walk's

`extractDirectives` returns `setDefs`/`defDefs` as **Maps**, so a name defined twice keeps
the **last** value, and everything downstream reads that map: the self-reference test, the
cycle walk, and the plural taint. This port kept every occurrence and resolved a name to the
**first**, which diverged in both directions at once — inventing diagnostics the reference
does not give and missing ones it does:

| template (one directive per line) | reference | this port, before 2026-08-07 |
|---|---|---|
| `#set %x% = %x%` / `#set %x% = B` | — | `variable.self-reference` |
| `#set %a% = plain` / `#set %a% = %b%` / `#set %b% = %a%` | two `circular-reference` | — |
| `#def %n% = plain` / `#set %n% = {a|b}` / `#set %n% = plain` / `{plural %n%:…}` | — | `plural.count-macro` |

The **count** is a separate contract, and a harder one, because it is a property of the walk
rather than of the graph:

```js
function detectCycle(current, defs, visited, rootPos, out) {
  for (const m of defs.get(current).matchAll(/%(\w+)%/gu)) {
    const ref = m[1].toLowerCase()
    if (ref === current) continue
    if (visited.includes(ref)) { out.push(diagAt(rootPos)); return }
    if (defs.has(ref)) detectCycle(ref, defs, [...visited, ref], rootPos, out)
  }
}
```

References are **not** deduplicated, so `#set %a% = %b% %b%` walks `%b%` twice; and the
`return` leaves only the current frame, so an outer frame keeps iterating after an inner one
reported. That template plus `#set %b% = %a%` gives **three** `variable.circular-reference`
diagnostics, all anchored at `%a%`'s definition. This port gave one, and the corpus compares
the multiset of codes.

So the walk is now the reference's own, with one prune that cannot change the output: the
global reachability set of §5's rewrite, used only to refuse to descend into a name that
reaches no cycle at all. A name that cannot reach a cycle can push nothing from any path.

Measured against `@spintax/core`: 4 000 generated definition graphs carrying duplicates,
self-loops and multi-references, **0 differences**, against controls of 985 (first-wins),
108 (taint over every occurrence) and 29 (one diagnostic per name).

**What the faithful walk costs, and why it is not free.** The prune bounds an ordinary
document and bounds nothing on a document built out of cycles, because there the answer
itself is large. Two shapes, both now in `tests/local_tests.dpr` because the first version
of this walk shipped without either:

| shape | recursive, over strings | iterative, over node indices | `@spintax/core` |
|---|---|---|---|
| one cycle of 400 | 378 ms | 14 ms | 505 ms |
| one cycle of 1 600 | 7 114 ms | 98 ms | — |
| one cycle of 6 400 | **99 419 ms** | 1 052 ms | — |
| one cycle of 25 600 | (did not finish) | 22 295 ms | — |
| converging DAG, 8 levels → 512 diags | — | 1 ms | 13 ms |
| converging DAG, 20 levels → 2 097 152 diags | — | 8 153 ms | 11 456 ms |

Two different things are in that table.

The **quadratic** part is the contract. A cycle of N produces N diagnostics and each is
found by a walk of N steps, so N² is what the answer costs; the reference pays it too. What
must not be paid on top of it is a dictionary lookup per step and a stack frame per level —
the first version was recursive over string names, which is the 99-second row, and 6 400
frames deep besides. Node indices, an explicit stack and a boolean path array make the same
walk 94× cheaper and bound the depth by the node count instead of by the machine stack.

The **exponential** part is not ours to fix. On a converging graph where every node reaches
the cycle, every distinct path ends in a push, so the DIAGNOSTICS are exponential in the
document: 507 bytes of `#set` lines produce 2 097 152 `variable.circular-reference` errors.
`@spintax/core` produces exactly the same count on the same input — 512, 8 192, 131 072 and
2 097 152 at 8, 12, 16 and 20 levels, verified 2026-08-07 — which is the strongest evidence
the walk is a faithful port, and also a family-wide property worth knowing before feeding a
validator an untrusted document. A walk cannot be cheaper than the output it must produce;
the only honest fix would be a family decision to cap or deduplicate the diagnostics.

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
`maxsize`, giving one element. Measured over 200 seeds in both engines on 2026-08-07 — the
reference yields exactly the three single elements, and so does this port. Remove the real
key and the boundary matters again: `[<xmaxsize=1>a|b]` has no config at all and renders
`Axmaxsize=1b`, the whole string being the single-separator form.

Being regexes, they have three further properties a hand-written scan does not get for free,
and this port was missing all three until 2026-08-07:

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
  (measured on FPC 3.2.2, 2026-08-07). The corpus's first NUL-bearing fixture arrived at the
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
