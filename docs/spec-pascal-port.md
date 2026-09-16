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
- **a `%var%` or a `{?…}` written directly inside `{…}`/`[…]`, in its raw `<config>` header or
  in a per-element separator is resolved as TEXT before the construct is split** — a
  pipe-joined value is a list of options or elements, a conditional's taken branch lands in the
  body first and its pipe separates them, `minsize=%n%` and `<sep=%S%>` take their values; a
  value at top level, with no construct around it, is not split (§5.9, §5.13)
- **a permutation element is its rendered text, trimmed; one that renders empty is dropped**
  along with the separator it carried, and the size pick counts what remains (§5.13)
- the post-process pipeline — *to the extent it is implemented*, see §4

**ALLOWED to diverge:** RNG selection results, internal architecture, diagnostic message
strings, performance.

**NON-GOAL:** cross-engine RNG-sequence parity. A seeded PRNG is reproducible *within* an
engine, not identical across engines. The deterministic fixtures inject an RNG strategy
precisely so they do not depend on it.

## 4. Measured state

Run on FPC 3.2.2 / i386-win32 against `spintax-js/packages/conformance/fixtures`
(333 cases total, 2026-09-16 — the corpus grew on 2026-08-06 with the cases the family
pinned from this port's divergences, once more with `plural.locale-missing` (§5.5), again
the next day with the two plural fixes §5.5 and §5.6 describe, on 2026-09-12 with the
nineteen `splice/*` cases §5.9 describes, and on 2026-09-13 with the 56 cases of
`@spintax/core` 0.8.0 and #79 — the post-process classes (§5.12), the wider re-read key
(§5.13), the prototype names and the first `diagnosticCount` assertions):

| fixture file | cases | passing |
|---|---|---|
| render-semantics | 124 | 124 |
| validate | 77 | 77 |
| render-postprocess | 67 | 67 |
| render-deterministic | 16 | 16 |
| comments | 13 | 13 |
| extract | 12 | 12 |
| neutralize | 10 | 10 |
| render-rng-selection | 10 | 10 |
| render-rng | 4 | — skipped by design (within-engine reproducibility only) |

**`PASS=329 FAIL=0 SKIP=4`** — the whole corpus, the 4 skips being `kind:rng` render
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
- **The classes are PCRE2's UCP ones, not JavaScript's and not ASCII** (since 2026-09-16,
  §5.12). Whitespace takes NBSP and NEL, the word boundary sees every script, the spacing
  digit is any `Nd`, a TLD is one case, and the lowercase test is strict everywhere. The
  decimal shield alone is ASCII. See §7 hazard 5.
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
monotonic on its own — `count-macro` is positioned once per block, and nested-brackets /
arity / locale-missing are mutually exclusive. Since 2026-09-16 `count-macro` is emitted once
per tainted **reference** (spintax-js#73, pinned by `diagnosticCount` in
`validate/plural-count-macro-per-reference`); the further copies of a block reuse the first
one's coordinates instead of asking the cursor for the same anchor again, which would restart
it from offset 1 per reference. `TestPluralLocaleMissing` pins that shape's
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

`ResolveConditionalsInText` (named `ResolveCountConditionals` until it gained a second caller
in §5.9) runs over the var-expanded count slot, before every check, which
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

**Corrected 2026-09-16: the class is PCRE2's, not JavaScript's.** `/u` turns on PCRE2_UCP,
so the plugin's `\S` is the complement of `\p{Z}` ∪ `\h` ∪ `\v`, and the 2026-08-18 fix below
copied the reference's JavaScript `\s`, which the reference itself had wrong (`@spintax/core`
0.8.0, `charclass.ts`). They differ on three code points: U+0085 and U+180E are whitespace,
U+FEFF is not. `IsUcpSpaceCp` now enumerates `\t \n \v \f \r`, space, U+0085, U+00A0,
U+1680, U+180E, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, pinned by
`conditional/nel-only-is-falsy` and `conditional/bom-only-is-truthy` and by the flipped local
checks, re-measured against the reference through a `#set` value and through the context.
**The "measured against the reference" below was true and still pinned a wrong answer:** a
measurement agrees with its instrument, and here the instrument had the defect. Read the rest
of this section with that in mind — U+0085 is no longer a control, and the differential's
zero was taken against JavaScript's class.

Fixed 2026-08-18: `IsJsSpaceCp` enumerated JavaScript's `\s` — `\t \n \v \f \r`, space,
U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF — and
`ConditionalTakesThen` walks the value as CODE POINTS through `SpCodePointAt`. A byte scan
sees NBSP as `$C2 $A0`, neither of which is an ASCII space, which is exactly how the
divergence survived. The ASCII half of the class is unchanged, so nothing that passed before
moves.

The class is enumerated, not taken from the RTL, for the reason the Unicode tables are
baked: the answer must not depend on which Unicode version the host compiler shipped. U+200B
and U+3164 are deliberately **outside** it — both are non-space to the reference and make a
variable truthy, and they are in `TestConditionalTruthiness` as the controls that stop the
class drifting into "anything non-ASCII". (Until 2026-09-16 U+0085 was a third control; under
the UCP class it is whitespace, see the correction at the top of this section.)

**Why nothing caught it.** No corpus fixture carried a Unicode space then (two do since
2026-09-13), and neither did any of
the 520-odd local checks of that day. It surfaced when a Codex review of the §5.6 work noticed the count slot
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
`ExpandVarsFixpoint` (the plural slots, and since §5.9 the body of a re-read construct).

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

**Every substitution is charged, the plain ones included** — since 2026-09-12, the family's
rule from `@spintax/core` 0.7.0 and PHP's from the start. This section used to say the
opposite: a value carrying no construct was free here, on the reasoning that it is substituted
and never expanded again and so cannot be part of an explosion, and two checks pinned the
shapes that charging it would truncate — a plain 100 KB `#set` referenced twenty times
(2 048 021 characters, nothing literal) and ten `#def` hops over one literal (102 402). The
reasoning was sound while a plain value could only ever be a LEAF. It stopped being sound the
day a re-read construct (§5.9) could hand `ResolveVariable` references its own textual
fixpoint had cut off at the budget: 2^12 of them, each to a plain 1 KiB value, were expanded
for nothing — 4 MiB out of a 1 MiB allowance, and an out-of-memory abort at 2^20. The
reference's review found it before release; the door is pinned shut here on both sides of the
bracket (`bomb/a-budget-cut-reference-is-not-spliced-for-free` and its top-level twin). The
price is that the twenty references now leave nine literal (1 126 466 characters); the ten
hops still give 102 402, because ten charges of 100 KB fit the purse and the eleventh is
allowed on a purse that is not yet empty. Both to the byte against `@spintax/core` 0.7.0.

Refusing on an EMPTY purse rather than on one the next substitution would overdraw puts this
engine at the same stopping point as the reference on the bomb itself — 599 193 characters
for `%a%`, to the byte, and the same number for `{%a%}`. Half of what it was before every
substitution was charged: the one at the depth cap used to be free. Worth knowing, and not a
contract.

`TestRenderExpansionBudget` asserts the CONTRACT, plus this engine's own bound: every shape
from the issue's table answers, a refused reference stays literal, an unresolved count still
erases, every substitution is charged and a budget-cut reference is never spliced for free,
and the budget is **per render**, not cumulative, so the second render of a compiled template
matches the first — the shape this could most easily have got wrong, since a host renders a
compiled template in a loop and a carried-over counter would leave only the first render
correct.

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

**Where this engine sits, re-measured 2026-09-12** against `@spintax/core` 0.7.0 (best of
three, no post-process), now that the family's remaining question is volume and time rather
than survival:

| shape | this port | reference |
|---|---|---|
| `#set` bomb, `%a%` | 172 ms, 599 193 chars | 67 ms, 599 193 chars |
| `#def` bomb | 156 ms, 838 857 chars | 33 ms, 838 857 chars |
| 200 `#include` lines over one bomb | 187 ms, 600 387 chars | 71 ms, 600 387 chars |

The volume is **identical to the byte** on every shape the two engines share, which is worth
recording precisely because the corpus deliberately does not assert it; every count halved or
better on 2026-09-12 when the substitution at the depth cap started being charged, in both
engines together. The time is 2.5–5× the reference (on 2026-08-18 it was 3–5×, on twice the
output) and well under the Python port's, which the family measured at ~5 s for the same
budget. It is linear in output, not super-linear — a terminating doubling chain costs
**~1.2 ms per KB** flat from 32 KB to 190 KB — so the constant is allocation and copying, where
a JavaScript engine has ropes and this one has strings. §3 does not ask performance to match,
and nothing here is a bound that fails to hold.

### 5.9 A `%var%` directly inside `{…}`/`[…]` is spliced as text before the split

Adopted 2026-09-12 from [`spintax-js#78`](https://github.com/investblog/spintax-js/issues/78)
(engine issue [#5](https://github.com/investblog/spintax-win/issues/5)), mirrored from
`@spintax/core` 0.7.0. A **parity-REQUIRED** surface (§3), and this port had it wrong from
its first commit — as did every other tree-walk engine of the family.

> **§5.13 widened the key this section describes** (`@spintax/core` 0.8.0, adopted 2026-09-16):
> a conditional, a size and an unquoted separator mark a construct too, and an element that
> renders empty is dropped. The mechanism below — retain the body, re-read it in the
> reference's order — is unchanged and still current; only the question "which constructs are
> marked" has a newer answer. The measurements here are 0.9.0's and are kept as taken.

**The report.** A brand preset `[<minsize=5;maxsize=7;sep=", ";lastsep=" and ">%List%]` over
a 57-name runtime list rendered all 57 names joined with `|` — no size pick, no shuffle, no
separators — into 131 published rows across 15 tenants. Both PHP engines have always split
it: their `expand_variables` runs a fixpoint over the whole text before any bracket is read,
so a `|` inside a substituted value IS an element separator. A tree walk builds its tree
before any value exists, so `[<…>%List%]` was one option holding a variable node, and
`ResolveVariable` handed a construct-free value back as finished text. The `|` was never
seen. Nothing in the corpus put a variable inside a bracket — 258 cases, not one — which is
how it shipped in four engines. Here the gate said `PASS=256 FAIL=17` the moment the corpus
grew.

**The rule.** A `%var%` that sits **directly** in an enumeration or permutation body is
spliced into that body as TEXT before the body is split on `|`. Directly means: at the top
level of an option; inside a conditional's branches (the reference resolves `{?…}` before it
expands, Stage 6a, so the taken branch lands in the body ahead of the split); or inside a
separator string — the config's `sep`/`lastsep`, a per-element `<…>`, and the
single-separator form `[<%S%>a|b]` are all text to the reference. It does NOT mean a nested
enumeration, permutation or plural: a value inside one of those is spliced when THAT construct
renders, and a `|` it carries belongs to it. What does not split, pinned as negatives: a
reference at top level with no construct around it (`%L%` → `x|y`), a top-level conditional's
branch (`{?L?%L%|none}` → `x|y`), and an undefined name (one literal element).

**How this port does it** (widened by #80 a release later — §5.13 has the current key; what
follows is the 0.9.0 shape this section documents). The parser keeps the construct's inner text
in `TNode.Raw` when `EnumHasDirectReference` / `PermHasDirectReference` finds a direct
reference — an iterative walk over the option lists that descends into conditional branches and
nothing else, plus the reference's `/%\w+%/` over the three separator strings. Every other
construct leaves `Raw` empty and renders the tree it always did, with the RNG order the corpus
pins. At render time
`SpliceConstruct` runs the reference's own order over that one body — conditionals
(`ResolveConditionalsInText`, the §5.6 pass, which now has two callers), the variable fixpoint
(`ExpandVarsFixpoint`), conditionals again — then puts the brackets back on, parses the
result with the ordinary parser and renders it. If the body did not change (an undefined name,
a reference the budget refused) it returns `False` and the caller renders the nodes it already
has; that is also what terminates the re-read, since after a converged fixpoint every
reference left is one expansion cannot touch. `SpCompile` keeps `Raw` in the cached tree, so
the compiled path splices exactly as `SpRender` does.

**The hop budget is 51 inside a bracket exactly as outside one.** The reference's fixpoint is
`<= MAX_VARIABLE_DEPTH` — 51 passes, once, over text — and a construct reached through a macro
re-parse has already spent `Depth` of those hops in `ResolveVariable`, so `PassesLeft` gives
it `51 − Depth` and the total is 51 in every shape. When the passes run out still changing,
whatever is left is **frozen** for the whole subtree (`TRenderOpts.Frozen`: `ResolveVariable`
answers the literal, `ExpandVarsFixpoint` does nothing): the mutual cycle leaves `%b%`,
`#set %b% = x%b%y` leaves 51 pairs, a 50-alias chain into `x|y` reaches the body as text on
the 51st pass and IS split (`splice/chain-into-a-list-is-split-on-the-51st-hop`), a 51-alias
chain leaves `%a52%`, and nothing below earns a fresh allowance. The reference's first cut
rendered the leftover at the depth cap instead — a 52nd hop, and one that hid a structural
value from the split; its review caught it, and the corpus carries the pin.

**The plural slots use the same arithmetic**, and a form list whose passes ran out renders its
pick frozen. They ran a flat 50 here and rendered the picked form unfrozen, so a 50-alias
chain in the count slot stopped at `%a51%`, non-numeric, and ERASED a block the plugin
renders, and a 51-alias chain in a form resolved to its end where the plugin leaves `%a52%`.
Both pinned in the corpus (`splice/plural-*`).

**Every substitution now charges the budget** — the reversal §5.8 records. It is a
consequence of this section: the re-read is the only path that can hand `ResolveVariable` a
reference whose value the fixpoint already refused, and a free plain-value leaf was then a
door.

**Two consequences a triggered construct inherits from PHP's text**, both measured on the
reference and pinned in `TestSplice`: a conditional's taken branch is trimmed at the element's
edge (`[{?f? %L% |y}|c]` gives `x c`, not ` x  c`), and an element that became empty is
dropped before the shuffle, so later draws shift. Neither happens on the untriggered path,
which keeps its tree — `[a|{?f?|x}|c]` still gives `a  c` — and the family recorded that
divergence as known rather than closing it, since no author has reported hitting it.

**One thing this broke, and how it was fixed.** The GSA front end (§5 of
`gsa-ser-conversion.md`) escaped a spin whose first option opens with `?` or `plural ` by
lifting that first character into a literal variable — `{%l1%a?b|c}` with `l1 = ?` — so the
prefix test would not see it. The splice puts the `?` back into the body ahead of the parse,
and the block was a conditional again, in every engine; `gsa_tests` caught it in the same
build that made the corpus green. The escape is now an empty enumeration in front of the
first option, `{{}?a?b|c}`, which renders to nothing, is not a `?`, and keeps the block a spin
over the author's own text — measured on the reference before it was chosen, no diagnostic.
`neutralize` shields brackets and not the pipe, so a neutralized value an author places
inside a construct still splits on its `|` (`splice/neutralized-value-still-splits-on-its-pipe`);
that is the family's contract, stated in the reference's `neutralize.ts`, and this port was
immune to it only by the defect.

**Verified** by the nineteen `splice/*` fixtures — the production preset shape, `#set` and
`#def` wrappers, `<sep="%S%">`, `lastsep="%S%"`, a per-element `<%S%>`, a macro value carrying
`{p|q}|r`, the three hop-budget pins and the three negatives, expected outputs taken from BOTH
PHP engines — and by 21 local checks for what no fixture expresses.

**And by a differential against the engine as it was, over a corpus generated once and fed to
every build** (1 760 documents × 6 configurations — first / last / seeded RNG, post-process off
and on — 10 560 renders per build, 2026-09-12). Three builds, so the two changes of this release
are attributed separately rather than blamed on each other: the engine before, the engine with
the splice only, and the engine as shipped (splice + the §5.10 draw fix).

| class | renders | splice only | draw fix only | as shipped |
|---|---|---|---|---|
| no direct reference, no one-option construct | 3 600 | **0** | **0** | **0** |
| no direct reference, WITH a one-option construct | 1 800 | **0** | 410 | 410 |
| direct reference, plain value | 2 400 | **0** | 146 | 146 |
| direct reference, value with a `\|` | 2 400 | 2 302 | **0** | 2 302 |
| control, built to differ | 360 | **360** | **0** | **360** |

Read the columns, not the totals. **The splice moves nothing that does not carry a pipe into a
construct** — zero on all three reference-free and plain-value classes — which is the claim that
a spliced value with no structural character re-reads to the very tree the parser built. **The
draw fix moves one-option constructs and nothing else**, wherever they appear.

The one-option stratum exists because the first cut of this table did not have it and claimed
"no direct reference ⇒ byte-identical under both changes" over a pool that could not express a
singleton at all — a zero that measured nothing, which is the trap §8 records twice and which
a review caught here. Split out and measured, the honest number is 410 renders of reference-free
templates moved by the draw fix.

The control class is the point: a differential that cannot fail is not evidence, and this repo
has shipped a parity regression behind exactly that mistake. The 98 triggered renders that did
NOT differ were read rather than assumed — they are RNG coincidences (`{a|%L%}` under a
first-pick RNG takes option 0, `a`, in both engines; `[a <%S%> | b]` shuffles the element
carrying the separator to position 0, where no separator is read) and the outcome SETS of all
five such shapes are identical to `@spintax/core` 0.7.0's, including the asymmetric
`["a, b", "b a"]` and all 24 permutations of `[a|%L%|b]`.

**Cost on deep nesting: the same order as before, a constant times three.** Nested constructs
with a direct reference at every level, best of three (the shape a splice could most easily have
made super-linear, built deliberately rather than inferred from the corpus):

| levels | no reference (baseline) | direct reference, plain value | reference engine, same triggered shape |
|---|---|---|---|
| 500 | 0 ms | 15 ms | 58 ms |
| 1 000 | 16 ms | 62 ms | 222 ms |
| 2 000 | 109 ms | 282 ms | 831 ms |
| 4 000 | 343 ms | 1 079 ms | 3 710 ms |

Both columns are quadratic in nesting depth, and so is the baseline — §5.6 already records that
this engine and the reference are quadratic there and that upstream calls bounding such input a
host job. The splice multiplies the constant, it does not change the order, and this port stays
about 3.4× faster than the reference on the triggered shape. An undefined reference at every
level costs less than a defined one (516 ms at 4 000), because the fixpoint changes nothing and
the re-read returns without parsing.

**What the splice widened, and what §5.11 then fixed: a deep runtime value reaches the parser
from a branch the RNG did not pick.** The re-read expands the body BEFORE the pick, exactly as
the reference does, so `{ok|%deep%}` parses `%deep%` whichever option wins; before, an unpicked
option was never walked. That was a new route to a cliff this engine already had, and a review
correctly refused to let it ship as one — so the parser was made iterative in the same release
(§5.11). Measured 2026-09-12, first-pick RNG, three builds:

| shape | before the splice | splice, recursive parser | **as shipped** | `@spintax/core` 0.7.0 |
|---|---|---|---|---|
| 10 000 levels, every shape below | renders | renders | renders | renders |
| 20 000-deep value, unpicked branch | renders | **`EOutOfMemory`** | **renders** | renders |
| 20 000-deep value, PICKED | `EOutOfMemory` | `EOutOfMemory` | **renders** | renders |
| 20 000-deep plain TEMPLATE, no variables | `EOutOfMemory` | `EOutOfMemory` | **renders** | renders |
| 30 000 levels, plain template | `EOutOfMemory` | `EOutOfMemory` | **renders** | renders |
| 40 000 levels, plain template | `EOutOfMemory` | `EOutOfMemory` | **renders** | renders |
| 50 000 levels | `EOutOfMemory` | `EOutOfMemory` | see §5.11 | heap abort |

Two things that table is worth reading for. The cliff was **never created by the splice**: a
plain nested template with no variables in it at all raised on the old engine at the same depth,
so any host taking an untrusted TEMPLATE was already exposed. And the fix did not merely restore
the old reach — every shape at 20 000 renders now, including the two that never worked. The
remaining ceiling is no longer in the parser at all — §5.11 has the shapes and the two walks
that now stop first, both of them recursive since long before this release. `SpValidate` is
unaffected at any depth here: it never builds a node tree, which is also why its clearing
100 000 levels says nothing about the parser and must not be quoted as if it did.

### 5.10 A one-option construct must not cost an RNG draw

Fixed 2026-09-12, found by a Codex review of §5.9. One option is not a choice, and asking the
generator for it spends a draw that shifts **every later choice in the document**.

The reference's `randomInt` returns `min` when `min === max` without touching the generator, and
says in its own comment that it mirrors the plugin's `random_int`. This engine already did that
at both of the permutation's draws — the size pick (`if min = max then pick := min`) and the
Fisher-Yates step — and `RenderEnumeration` was the one site that did not. So a one-option spin
followed by a two-option one, over the injected sequence `[0,1]`, rendered the SECOND option of
the second spin here and the first one in the reference.

Ordinary content reaches it. A spin with no `|` is a one-option enumeration, and the GSA guide's
own example of a braced placeholder in prose is exactly that shape. The corpus does not gate it:
no fixture pairs a one-option construct with a later choice, and §3 makes cross-engine
RNG-sequence parity a non-goal, so neither behaviour was ever a parity defect — but one of them
matches the reference and the other was an inconsistency inside this engine.

**How it surfaced, and why that matters more than the fix.** §5.9 gave the GSA front end a new
escape for a SER block opening with `?` or `plural `: an empty enumeration in front of the first
option. An empty enumeration is a ONE-option enumeration — `splitTopLevel('')` yields one empty
part, here and in the reference — so every escaped block silently advanced the stream. The old
escape, a lifted first character, spent nothing, so the conversion had been RNG-neutral by
accident and stopped being so. The review found it by reading the draw, not the output: the GSA
suite asserts outcome SETS, and a construct that spends a draw it should not still reaches every
one of its options, just under different seeds. That is the general lesson — **an outcome-set
check cannot see a draw being spent** — and both suites now carry sequence-driven checks that
can (`TestSingleOptionDraw`, and `literal/escape-is-rng-neutral` end-to-end through the
converter). Removing the short-circuit again fails three of the engine checks and two of the GSA
ones, which is how they were confirmed to be capable of failing at all.

**What moves.** Any template with a one-option construct renders a different draw sequence than
it did, so seeded output changes for it — and for nothing else. The §5.9 differential puts a
number on both halves: 410 of 1 800 renders in the stratum built from one-option constructs, 146
more where a spliced plain value produced one, and **zero** across 6 360 renders of every class
without one. An empty **permutation** was already neutral (`total = 0` returns before any draw)
and is unchanged.

### 5.11 The parser is iterative, and the wall was memory rather than the stack

Rewritten 2026-09-12, in the same release as §5.9, because a Codex review would not let the
splice ship while it widened the reach of a recursive parser. `ParseSequence` was the deepest
recursive walk in this engine — the hazard §7 names in one line, *follow nesting iteratively
where input depth is unbounded*, and the one the Python port paid for before us. It was not the
only one, and an earlier draft of this section wrongly called it the last: **the render walk and
the tree's own destructor still recurse**, which is recorded at the end of this section rather
than papered over.

**The cause was not the one the hazard predicts, and that decided the design.** A recursive
descent costs a stack frame per level, so the expected failure is a stack overflow. This engine
raised **`EOutOfMemory`**, and the reason is that every level copies its own inner text out with
`Copy` and a recursive walk keeps EVERY ancestor's copy alive in its frame until the whole
subtree finishes. An option holding the rest of the document is then quadratic in the document:
20 000 levels of a 60 KB template held on the order of 450 MB of substrings. Enlarging the stack
would have fixed nothing. Reading the exception class rather than assuming the textbook failure
is what pointed at the right fix.

**The shape.** One explicit stack of jobs, each a `(text, target list)` pair, drained to
exhaustion. A construct's node and its child lists are created and attached to the tree
**immediately**; only the child TEXT is deferred. Two consequences fall out of that ordering:
the whole tree is reachable from the result at every moment, which is what lets the `except`
free all of it rather than leak the part already built, and the order jobs are drained in cannot
matter, because each one writes only into its own list. Each level's text is released as soon as
that level is scanned — the job slot first, the local right after — so what stays live is the
current text and its siblings instead of every ancestor at once.

The direct-reference marks of §5.9 were held not to be decidable during the scan, since a
construct's children do not exist yet: every candidate was recorded with `Raw` set tentatively
and one flat pass at the end cleared it on the constructs that turned out not to hold one,
through `EnumHasDirectReference` / `PermHasDirectReference` over the parsed options. **That was
wrong, and §5.13 removes the pass** — the prefilter below computes the same predicate over the
same strings, so the mark is final when it is taken.

**That tentative `Raw` undid the fix, and two review rounds were needed to get it out.**
Retaining a construct's whole inner text until the finalize pass keeps one copy alive per
level — the same Θ(n²) the recursion had, moved out of the stack frames and into the tree. It
bought a bigger constant, not a better order, and the measurement said so plainly: the ceiling
went from under 20 000 to about 35 000, which is roughly the √3 that a threefold drop in
bytes-per-level predicts, where a real fix removes the quadratic altogether. **A fix meant to
change an order has to be checked against the order, not against "it got better".**

The cure is a prefilter, `MayHoldDirectReference`, run before a body is retained, with the
finalize pass then the authority (it is the authority itself since §5.13, which deletes that
pass). Its hard requirement is no FALSE NEGATIVES — a body wrongly
rejected loses its `Raw` and renders the old, wrong output — while false positives cost only
the memory the prefilter exists to save. The first cut of it tested whether a `%name%` token
appeared anywhere in the body, and that is wrong in exactly the way that matters: in a chain of
ancestors wrapped around ONE reference, every ancestor's body contains it as a substring, so
every ancestor retained its body and the quadratic came straight back with a single `%x%` in
the document. The measurement meant to prove the prune could not see it, because its
100 000-level chain contained no `%` at all — a corpus that cannot express the counterexample,
which is the trap §8 records twice and which caught this work twice more. Measured after the
second round: one reference wrapped in 40 000 ancestors raised `EOutOfMemory` under the flat
test and parses under the level-aware one.

So the prefilter walks the body at the construct's OWN level — stepping over a nested
enumeration, permutation or plural whole, entering a conditional's branches, and treating an
unmatched bracket as the literal the parser treats it as. A deep chain where every level really
does carry a direct reference stays quadratic.

Two of those sentences are superseded by §5.13, and are kept here because the rounds that
produced them are the reasoning this design rests on. **A conditional now ENDS the walk
instead of being entered** — #80 marks on sight, so what its branches hold stopped mattering —
which retires the span rule below along with the defect it fixed. And **a chain that retains at
every level no longer exists**: §5.13 gives retention to the topmost marked construct of a
chain only, so the quadratic is removed rather than tolerated. The reference engine does not
keep these bodies at all — 0.8.0 indexes one text and makes children SPANS of it, which is why
it is linear where this port is quadratic in TIME.

**Separators are read, not guessed, and it took four review rounds to learn that.** Three
successive cuts tried to spot a permutation's separators in the raw body text before retaining
it, and every one was wrong somewhere. Brackets inside a separator are characters, so skipping
them the way the walk skips a nested construct hid the reference in `[<sep="[%S%]">a|b]` and
printed a literal `%S%`. The config and per-element grammars disagree about a quote — a config
ends at the first `>` outside quotes (`ParsePermConfig`), a per-element separator treats the
quote as text and ends at the first `>` at all (`extractTrailingSep`) — so reading one of them
made `[a <"[%S%]> | b]` look unterminated. And flat-testing every angle region to be safe made
ordinary option text a false positive at every ancestor: in `[a<…>b]` wrapped around one
reference, each level's angle region contains the whole subtree, and `EOutOfMemory` came back
at 32 000 levels — the very cost the prefilter exists to prevent. The first two were output
bugs, the third was memory, and a fourth version of the angle scan was also quadratic in TIME
under a comment claiming one linear pass (187 ms at 20 000 bare `<`, 15 578 at 160 000).

None of it was necessary. By the time a permutation's body is judged, `ParsePermConfig` has run
and the per-element separators are collected, so the EXACT fields the authority reads —
`PermSep`, `PermLastSep` and each option's separator — are already in hand. `MakePerm` reads
those itself. Only a leading region is config and only a trailing one on a non-final part is a
separator; everything else between angle brackets is option text. The prefilter itself no longer knows what a separator is. Measured on the angle-wrapped
permutation chain: `EOutOfMemory` at 32 000 before, parses after.

**Which fields, and with which test, is §5.13's correction and not this section's.** #80 showed
the PARSED `sep`/`lastsep` are the wrong two: `minsize=%n%` and an unquoted `sep=%S%` leave no
trace in them, so 0.7.0 never re-read those constructs at all. `MakePerm` judges the RAW header —
the text `ParsePermConfig` consumed — plus each per-element separator as extracted, and the test
is `HoldsTextForReread` (a reference OR a whole conditional), not `HasReferenceText`. The lesson
survives the correction intact: it is still the parse's own product being read rather than a
guess at the raw body, and the raw header qualifies because it is precisely what the parse
consumed. What changed is WHICH product answers the question.

**And "option text" has to mean the text each option KEEPS, which a ninth round caught.** The
first cut of the exact read still ran the structural scan over the permutation's raw body — and
the raw body holds separators the parser DISCARDS. A trailing separator pending for an empty
part is overwritten on that empty iteration and never attached, so in `[a <%x%> || …]` there is
a `%x%` that no node will ever hold; the authority rightly finds no direct reference there, and
the raw scan found one at every ancestor. The scan now runs, inside the option loop, over each
kept option's trimmed text — the very text pushed as that option's parse job and later walked by
the authority. With the parsed separators on one side and the kept option texts on the other, the
decision reads exactly what the authority reads, and nothing it does not.

**Enumerations needed the same, and my argument that they did not was wrong.** An enumeration
keeps every part, empty ones included, so its joined body looked equivalent to its option texts,
and I asked the reviewer to confirm that. The equivalence fails on bracket counting:
`SplitTopLevel` counts depth with a SIGN, so a stray `]` followed by a stray `[` inside an option
leaves the next `|` a real cut, and that `[` is a literal in the part the parser reads — which
makes the reference after it direct. A scan over the joined body starts a fresh count at the `[`,
pairs it with a `]` in the NEXT option, and steps over the reference: `{][%L%|]}` rendered its
value unsplit, where the reference offers `]`, `][x` and `y`. So an enumeration is judged per part
too. **Both construct kinds now feed the prefilter exactly the strings their parse jobs receive**,
which is the only form of the equivalence that holds by construction rather than by argument.

**What the prefilter buys is retention, and nothing more is claimed for it.** It is not linear in
TIME, in two ways the parse shares. Over NESTED constructs the per-construct calls sum to Θ(n²),
because each one's `FindMatchingClose` crosses its subtree — the angle-wrapped permutation chain
costs 110 ms at 2 000 levels and 30 s at 32 000. And even within ONE body, a run of unmatched
opening brackets makes every `FindMatchingClose` rescan the rest of the body before it gives up.
`ScanInto` calls the same function on the same text, so the prefilter adds a constant and not an
order, and §5.6 already records that this engine and the reference are both quadratic on such
input with upstream calling it a host job. What it removes is the Θ(n²) MEMORY of one retained
body per level, which is what the recursion cost and what the tentative-`Raw` cut cost after it.

**The property is verified against a build with the prefilter AND the separator read compiled
out**, since a false negative is the only direction that would be a behaviour bug. Six corpora,
**12 810 renders, all identical** — including a set of discarded-separator shapes (`||` after a
separator, separators around empty parts, a leading empty part) and a set of signed-depth shapes
(stray brackets straddling a pipe): the 1 760-document differential; 332 adversarial shapes
putting a reference in an option, a permutation element, `sep`, `lastsep`, a per-element
separator, the single-separator form, either branch of a conditional, an inverted one, two
conditionals deep, and in pairs, each also wrapped one to three levels deep, plus the shapes
where the reference sits inside a NESTED construct and the shapes with an unmatched bracket
around it; and two sets of separator shapes — brackets and braces in a separator, an unmatched
quote, a quoted `>`, nested and bare angle brackets. None of it is a vacuous zero — every one
of the six corpora is also shown to differ from the pre-splice engine, so each exercises the
splice it is asserting about:

| corpus | renders | differ from pre-splice |
|---|---|---|
| differential | 10 560 | 3 218 |
| adversarial positions | 1 992 | 1 302 |
| separators holding brackets | 66 | 48 |
| separator grammars and angle text | 102 | 48 |
| discarded separators | 48 | 6 |
| signed-depth stray brackets | 42 | 28 |

Every local check in this family was confirmed capable of failing by building the mutant that
breaks it. Removing the parsed-separator read fails exactly the six separator checks — including
both quote-grammar ones and the reference hidden past a quoted `>` — and nothing else; stopping
the walk from entering conditionals fails exactly the two nested-conditional checks plus the two
branch-trimming ones.

**That second mutant describes today's engine, and the four checks pass anyway** — which is not a
contradiction but the point of #80. Not entering a conditional was a false NEGATIVE when the key
was "a reference somewhere inside a branch": no reference found, no mark, old output. Under #80 a
conditional marks ON SIGHT, so refusing to enter it is a false positive at worst, and
`splice/reference-two-conditionals-deep-still-splits`, its permutation twin,
`splice/taken-branch-trimmed-at-the-edge` and `splice/empty-element-dropped` all still hold.
Read the sentence above as the 0.9.0 release's evidence about the key it had.

**Ownership on the exception path.** Every node is attached to its parent list BEFORE anything
is hung on it, each owning list is reserved to its final size before it is filled, and the
attach itself goes through `AttachNode`, which frees the node if the list's own growth raises.
`TNode.Destroy` and `TPermOption.Destroy` tolerate the nil fields that ordering leaves behind,
and `pend` is allocated before the result list so that failing to allocate it cannot strand
one. The plural is filled through `FillPlural` after it is attached, for the same reason — it
was the last node kind still built complete and handed over afterwards. With all of that in
place freeing the result frees a half-built tree completely — through `FreeNodeTree` since
§5.14, which is subject to the same invariant and states it there.

It took two rounds to get there, and the first one is the lesson: the original code had the
order backwards in five places — a conditional's two child lists, both owner lists, a
permutation option, and worst of them a literal node holding the largest string the scan
produces. Fixing those left a subtler hole, that `list.Add(node)` can grow the list and raise
BEFORE taking ownership, so the one object the invariant could still lose was the very node
being attached. Both were found by reading the invariant against the code rather than trusting
the comment that asserted it, and neither could have been found by a test: they only show under
a failing allocation.

**Verified as a pure refactor, which is the only acceptable result for it.** The §5.9
differential — 1 760 documents × 6 configurations, 10 560 renders — is **byte-identical** to the
previous build across every class, while the same harness reports 3 218 differences against the
pre-splice engine, so it is not blind. The corpus, both local suites and both GSA suites pass
unchanged. What moved is only the depth table in §5.9: 20 000 levels now parse and render in
every shape, including the two that never worked in any earlier release.

**Where it stopped then, and in which walk.** Parsing stopped being the limit here: an
enumeration chain 100 000 levels deep parses. What failed past that was the two walks that were
still recursive at this commit — the render walk (`RenderNodes` →
`RenderConditional`/`RenderEnumeration` → `RenderNodes`) and the tree's own destructor, which
recursed through the owned child lists. They failed with `EStackOverflow`, not `EOutOfMemory`,
which is how they are told apart from the parser's old wall:

| shape, measured on the build this section shipped | outcome |
|---|---|
| enumeration chain, **parse only**, 100 000 levels | parses |
| enumeration chain, parse + render + free, 40 000 and 50 000 | fine |
| enumeration chain, 60 000 | `EStackOverflow`, in the render walk and in the destructor alike |
| enumeration chain, parse + **free only** (never rendered), 60 000 | `EStackOverflow`, and the process does not survive it |
| conditional chain, parse + render + free, 50 000 | fine |

The parser cleared every row; what stopped was the walk after it. None of it was new behaviour:
both walks recursed before that release and the parser simply failed first, so the limit was
never reachable. **§5.14 closes this** — both walks are iterative now and no row in that table
fails any more.

**The deep depths are measured, not gated**, and deliberately so: a 20 000-level render costs
7.6 s and the local suite runs twice on every push. The suite pins the ROUTE at 5 000 — a
regression that made an unpicked branch raise again fails there — while the numbers live here,
the same arrangement §5.6 uses for its nesting-cost table.

### 5.12 The post-process reads characters the way PHP does

`@spintax/core` 0.8.0 (2026-09-13) and the unreleased #79 on its `main` moved the cosmetic stage
to the classes of the PHP engines, measured on both of them. This port had copied the
reference's belief that the plugin's patterns were ASCII ("no PCRE_UCP") and its JavaScript
case folding, so it inherited every defect: `и т.д.` rendered `И т. Д.`, `пример.рф` rendered
`пример. Рф`, and a no-break space before a comma survived. The corpus added 24
`postprocess/*` fixtures; 18 failed here, and all 18 pass.

| site | before | now |
|---|---|---|
| whitespace, every pass but step 6 | ASCII six | `UcpSpaceAt`: PCRE2 UCP, NBSP / NEL / U+180E in, U+FEFF out |
| word boundary: email end, domain both ends, multi-dot abbreviation start | ASCII `\w` | `IsUcpBoundaryAt` / `PrecededByUcpWord`: L, N, Mn, Pc |
| decimal shield | ASCII | unchanged — PHP writes it without `/u` |
| digit in the two spacing lookaheads | `0-9` | `Nd` |
| domain label letters | folded L | strict L |
| TLD | a letter, then letters / digits / hyphens | ONE case (#79): L minus Lu/Lt, or L minus Ll; caseless scripts fit either |
| punycode TLD | `[a-zA-Z0-9-]`, counted in bytes | plus U+017F and U+212A, counted in code points |
| email local part | ASCII | plus U+017F and U+212A (PCRE2's caseless `[a-z]`) |
| lowercase after a block tag | folded Ll | strict Ll; only the tag NAME is caseless, U+212A included |
| single-abbreviation lookbehind | folded L | unchanged — the reference still writes it `giu` |

Three new generated tables carry it (`UCP_WORD_RANGES`, `ND_RANGES`, `LU_LT_RANGES`), from Node
24's Unicode 17.0 — the regenerated file is byte-identical to the old one in every existing
table. **The accepted cost of #79**, pinned by the corpus so nobody files it: a Title-case second
half reads as a sentence, `Yandex.Money` renders `Yandex. Money` and `info@example.Com` is not
shielded.

**A byte-string hazard the UCP class created.** `SpCodePointAt` decodes a stray UTF-8
continuation byte to its own value, and `$85` and `$A0` are NEL and NBSP. Under the ASCII class
that was harmless; under UCP, a pass stepping one byte at a time sees whitespace inside U+0405
(`D0 85`) or U+0420 (`D0 A0`) and deletes half of the letter before punctuation. Every pass that
tests the class now steps by code point, `ShieldPass` included, and two local checks pin it —
confirmed by mutation: the byte-stepping version fails exactly those two. The UTF-16 build has
no continuation units and cannot see it — the same shape as the Spanish-opener defect recorded
at step 7a of `SpacingPasses`, where `$BF` read as an inverted question mark.

Local suite: all 39 post-process checks were re-measured against the reference; five had pinned
the ASCII reading and were rewritten from its output, and fifteen were added for shapes the
corpus does not carry (U+180E, an Arabic-Indic digit, a Kelvin sign in a tag name and in an email,
a combining mark and U+203F as word characters, the punycode code-point count past 59, and the
four lead-boundary shapes below, which all fail against a mutant restoring the old skip). Cost on
ordinary text, 1 MB best of three: Russian prose 125 → 141 ms, English 156 → 172, HTML 125 → 141
(measured before the linearity work below). The reference paid a third on shield-heavy text for
the same change.

**The UCP boundary woke a dormant quadratic, so the shields are linear in the same change.**
`ShieldPass` tries a scanner at every start, and the email and domain scanners walk a whole run
from each one. Under the ASCII boundary a non-Latin start was rejected at once, so only Latin
runs paid; under UCP every script does. Found by review before commit, one render of a single
line:

| shape | `v0.9.0` | UCP, first cut | now | reference |
|---|---|---|---|---|
| Cyrillic letter + `.` × 40 000 | 81 ms | 75.8 s | < 16 ms | 14 ms |
| Cyrillic letter + `-` × 40 000 | 68 ms | 18.0 s | 16 ms | 4 ms |
| U+017F × 40 000 (email local part) | 63 ms | 1.7 s | 16 ms | 3 ms |
| `a.` × 40 000 (ASCII — quadratic in every release) | 48.5 s | 68.8 s | < 16 ms | 4 ms |

The fix is the reference's own argument, not a new one. A scanner may return a NEGATIVE length,
meaning "no match here nor anywhere in the next that many code units", and `ShieldPass` copies
the stretch. Email: every start inside one run of local-part characters reaches the same `@` or
none, so a failed run is skipped whole. Domain: an attempt that fails at the start of a chain of
labels fails at every later start in it — prefix the chain's own labels to a later match and it
matches here — so a failure skips the chain. The chain argument has one exception, which the
reference's scanner shares: a later start whose own label begins `xn--` is not reachable by
prefixing, so `a-xn--b.com` shields `b.com` here and `xn--b.com` in the plugin. Shield level
only — the four characters left out cannot start a lead and no pass can alter them — and
measured as such in review: 48 shield-level differences over 40 025 adversarial strings, zero
output differences.

At 640 000 repetitions every run shape measured renders in 0.2–0.6 s and scales linearly.

**And a capitalizer defect as old as the stage, found by the same review.** After a sentence end
or a line break, steps 9 and 11 skipped the whole lead when no lowercase letter followed it. The
regex resumes ONE character after the boundary, so a `.` or a line break inside a tag in that lead
is a boundary of its own: `Done. <img alt="Hello. world">` keeps `world` lower case here and
capitalises it in the reference and PHP. UCP made it more reachable, since NBSP, NEL and U+2028
now extend a lead. Resuming inside the lead with a fresh `ScanLead` per boundary would be
quadratic on a run of line breaks, so `IndexLeads` builds the reference's index instead: the lead
end for every code-point start and the next `>` for every position, once per pass. The block-tag
test uses the same `>` index, and that removed two quadratics nobody had filed: at 640 000
repetitions `<p` went from **143.9 s to 374 ms** and `.<` from **194.1 s to 405 ms**. The index
costs three Integer arrays per pass, about 12 bytes per code unit while a pass runs.

**Verified by differential.** 80 000 generated post-process strings over two seeds (Latin, Cyrillic
and CJK letters, titlecase and modifier letters, U+0301 / U+203F / U+017F / U+212A, Arabic-Indic
digits, every space the dialects disagree on, `.,;:!?…-@%+/`, tags and attributes, openers, URL
schemes, abbreviations). Each string went through the reference and through an FPC probe from
this tree: **0 differences**. The controls: `v0.9.0` differs on 15 419 and 15 324, and a mutant
that restores the lead skip differs on 134 and 129. The generator's first cut produced negative
indices and filled most strings with the word `undefined`, a narrower alphabet than intended.
That was caught by reading its output, and every number above comes from the corrected run.
The review's own run was 40 046 strings, 0 differences once the lead skip was patched.

Recorded for the family, not changed here: the single-abbreviation lookbehind is still `giu` in
the reference, where U+0345 counts as a folded letter. PCRE2 does not fold properties, so PHP
probably shields `St.` after U+0345 where the reference and this port do not. Not measured: no
PHP on this machine.

### 5.13 A conditional, a size or a separator inside a construct is text too (#80)

`@spintax/core` 0.8.0 widened the key that decides which constructs are re-read as text. §5.9
marked a construct when a `%var%` sat directly in it; the plugin resolves more than that before
it reads a bracket, and this port mirrored the narrow key. Thirteen fixtures, all failing here:

| template | before | now, and in both PHP engines |
|---|---|---|
| `[<minsize=%n%;maxsize=%n%>a\|b\|c]`, `n=1` | all three elements | one element |
| `[<sep=%S%>a\|b]`, `S=", "` | `b a` | `b, a` |
| `[{?f?a\|b\|x}\|c]` | `c b\|x` — a raw pipe | three elements |
| `[<sep=", ";lastsep=" and ">{?f?live casino}\|slots\|poker]` | `slots, poker and ` | `poker and slots` |
| `[<sep=", ">slots\|{live casino\|}\|poker]`, empty option picked | `slots, , poker` | `slots, poker` |
| `[a<1>\|{x\|}<2>\|b]` | `a12b` | `a2b` |

Three rules, each read from the reference's own parser and renderer:

- **A conditional marks ON SIGHT**, wherever a `%var%` would: at the top level of an option, in
  a raw `<config>` header, in a per-element separator. Stage 6a resolves it before any bracket
  is read, so its taken branch's pipe separates options, an empty branch leaves an empty
  element, and whitespace at a branch's edge is the element's edge. The old key looked INSIDE
  the branches for a reference, which found the one effect a reference has and missed those
  three. `MayHoldDirectReference` therefore stops at a conditional instead of entering it, and
  the authority (`ListHasTextualMark`) is a flat test of each option's top level.
- **The header is read RAW**, not through the parsed config fields. A size reference never
  reaches them (`minsize=%n%` is not digits, so it parses to nothing) and neither does an
  unquoted `sep=%S%` (it parses to the default) — which is exactly why 0.7.0 never re-read
  those. Per-element separators are read as extracted. A header or separator mark is decided
  in `MakePerm` and is definitive, so such a node never joins the finalize pass.
- **An element is its RENDERED text, PHP-trimmed, and one that renders empty is no element** —
  dropped together with the separator it carried, while the separator written after it still
  belongs to the next. The size pick and the shuffle count what remains. This applies whether
  or not the construct was re-read: the plugin resolves nested spins before it splits.

**What it does not move.** A construct whose re-read changes nothing structural draws exactly
as its tree did — the corpus pins that with `splice/conditional-without-pipes-keeps-draws`, and
`draw/dropped-element-spends-fewer-draws` pins the other half here: a dropped element does not
spend the shuffle draw it would have, which an outcome-set check cannot see (§5.10).

**Verified.** 140 000 generated construct-heavy templates (conditionals with empty, piped and
padded branches, references and conditionals in configs and separators, overlapping `%…%`
tokens, nested spins, HTML-tag configs), each rendered under three RNG strategies — `first`,
`last` and an injected sequence: 420 000 renders, **0 differences** from the reference, against
5 100 per 20 000 for the previous commit before the overlapping tokens were in the alphabet and
12 400 after, which is the control that makes the zero mean something. The review added 30 072
adversarial templates of its own, aimed at brace balance in headers and separators. One local check
flipped: a conditional with no reference in it used to leave the empty element in place, and
was the CONTROL for the narrow key; the reference now renders `a c` there too.

**Cost: marking on sight made a template ABORT, and TIME was the wrong thing to measure.** A
marked construct keeps its inner text, and a body contains every body below it, so a chain of
marked constructs costs Θ(n²) memory — the very thing `MayHoldDirectReference` exists to bound.
The first version of this section measured the nesting shapes in milliseconds, found them level
with the previous commit and concluded the retention did not dominate. It dominated in the other
dimension: on `[{?f?a|b}|` × 16 000 the heap went from 26 MB to 1 381 MB, and a 1.6 MB template
of 4 000 padded levels raised `EOutOfMemory` out of `SpRender`, which §9.2 says never happens on
content. Found by review, which measured the peak instead of the clock. The same shapes peak at
43 MB now, and the instrument is the lesson: when a change makes something be KEPT, time cannot
see it.

**A 64 MB cap stood here for one commit, and it was the wrong fix.** `SP_PARSE_RAW_BUDGET`
bounded what one parse could retain; past it a construct kept no body and rendered the tree it
was parsed into — the PRE-#80 answer for it. Two justifications for it were written into this
section and both were refuted. The first said the cap only ever refuses harmless retentions; a
build with the cap at 1 KB killed that, differing from the reference on 110 and 120 of 20 000
generated templates, because bodies are refused across SIBLINGS and not only down a chain. The
second said distance made it safe — "no generated template comes within three orders of magnitude
of 64 MB". Review refuted that by building the counterexample: retention sums to roughly
`document × marked depth`, so the reach is SIZE × DEPTH, and a 1.4 MB template renders a raw `|`
into finished text where the reference splits it. That is the production defect of #78 again, in
the release that was supposed to complete #78's family of fixes. **A generated corpus measures
what its generator can build; it is not a bound on what a host can send.**

**What ships instead: a descendant of a RETAINED construct never takes a body of its own.** If
the ancestor's re-read fires, its whole subtree is re-parsed out of the spliced text and these
nodes never render. If it does not fire, no descendant's body could have changed under the same
passes either — a descendant's body is a SUBSTRING of the ancestor's, the passes (conditionals,
the fixpoint, conditionals) are the same text transforms wherever they run, and a subtree frozen
for running out of hops is frozen for the descendant too. So one body is kept per marked CHAIN
instead of one per marked LEVEL, the quadratic is gone rather than bounded, and no cap is needed:
the cliff shapes peak at **43 MB** against 105 MB, with the 1.6 MB template that once aborted
unchanged in time.

This rests on the prefilter being not a necessary condition that an authority later refines —
how it was introduced — but the **same predicate, computed earlier**. Each option's parse job is
pushed with exactly the text `MayHoldDirectReference` is given; `ScanInto` and the prefilter then
make the same three decisions at the same positions (a matched `{` is a conditional exactly when
`RecognizeConditional` says so over the same span, otherwise an enumeration or plural, neither of
which marks; a matched `[` is a permutation; `%` + `IsAsciiWord`+ + `%` is a reference; an
unmatched bracket and a barren `%` advance one character). That reading is the proof, and it is
why `pend`, the flat finalize pass and the two node-walking predicates are deleted rather than
kept as a net — the descendant rule is only sound if a taken mark is final, so a net that could
clear one would have made it unsound.

**Verified**, all against `@spintax/core` through its own pipeline: the four starvation shapes ×
3 RNG strategies, where the capped build diverged on 9 of 12 renders and this one on none, with
a cap-free control document that matches on both builds; 200 288 generated templates × 3
strategies byte-identical to both the previous build and the reference. That generator was fixed
first — `gen4` passed no closing bracket to its top-level `construct()`, so every template built
for the #80 review ended in an UNMATCHED one and the outermost construct, the only level with no
ancestor above it, was never exercised. Controls: a mutant that marks descendants without the
ancestor keeping anything fails three of the six new local checks and moves ~1 500 of 50 072
templates; one whose re-read inherits the flag fails all six and fifteen older splice checks.
Parsing over spans of one string is still the backlog item — it would make a retained body two
integers and close the TIME quadratic that remains.

**The reference is no longer the same shape here either:** 0.8.0 made deep nesting linear with a
side index and answers those chains in 43 ms and 111 ms against this port's 265 ms and 4.8 s.
Performance, which §3 allows to diverge, and the one place where this port is now materially
slower than the engine it mirrors.

**One older defect surfaced with it.** `ExpandVarsFixpoint` advanced ONE character past a
`%name%` it recognized but did not substitute — an unknown name, or one the budget refused — so
the token's closing `%` could open the next reference: `%nope%b%nope%` with `b` defined rendered
`%nopeanope%`, a name the author never wrote. The reference is a global `%(\w+)%` replace, whose
matches cannot overlap. Only the re-read path scans that text instead of parsing it, which is why
no fixture and no tree-path check could see it. Two local checks pin it.

### 5.14 The render walk and the destructor are iterative

§5.11 made the parser iterative and said what would fail next; this is that. `RenderNodes` is one
loop over an explicit array of frames, one frame per node LIST, mirroring the reference
(`render.ts:357-408`, family issue #68). `FreeNodeTree` frees a tree with a worklist instead of
letting `TObjectList<T>.OwnsObjects` recurse. Both were the last recursive walks over unbounded
input, in an engine whose §7 names that as a port hazard and whose §9.2 promises never to raise on
content.

**The contract is the RNG draw ORDER, not the output.** A walk that renders in a different order
changes seeded output while every unseeded check stays green, so the shape is copied exactly:

- an enumeration **draws before it descends**, and an unpicked option is never walked and spends
  nothing; one option draws nothing at all (§5.10);
- a permutation renders every element first, in source order, and only then draws the size and
  shuffles — `AssemblePermutation` is the old `RenderPermutation` from the trim onward, reading
  the already-rendered texts, so neither draw can move above the last child;
- the expansion budget is a second ordered resource, charged in `ResolveVariable` before it
  decides to descend, and it moves with the frames if they move.

FPC 3.2.2 has no anonymous methods, so the reference's `pending = {lists, done, assemble}` cannot
carry a closure. It does not need one: the pending carries the node POINTER and a kind, and
assembly is a two-case dispatch — `pkSingle` takes the one child's text, `pkPerm` assembles.

**Three walks stay recursive on purpose, and each is bounded:** `ResolveVariable` re-parsing a
value at `Depth+1` (`MAX_VARIABLE_DEPTH = 50`), a frozen plural form or a frozen spliced body, and
`#include` (`MaxIncludeDepth`). These are the three sites that need a DIFFERENT `TRenderOpts`,
which is why the reference keeps `opts` per walk rather than per frame. The frozen path cannot
chain, because `ExpandVarsFixpoint` sets `converged` before it bails on `Frozen`, so a frozen walk
always takes the converged branch and never starts another.

**A claim this section made in draft, and measurement refuted.** The plan asserted that a
converged spliced body must go on the frame stack because a chain like
`[<sep=%s1%>[<sep=%s2%>[…]]]` would cost one `SpliceConstruct` frame per level. It does not: the
fixpoint runs over the WHOLE body, so the outermost splice resolves every separator below it at
once and the levels under it are ordinary nodes. The recursive build answers that chain at 50 000
levels — which is how the claim died. The bodies still go on the frame stack, for the honest
reason that the picked form's own tree is unbounded in depth and one mechanism for both is smaller
than two.

**Ownership is the hazard the reference cannot have**, being garbage-collected. A spliced or plural
body is a tree THIS walk parsed, so the frame carries it in `Owned`, it is freed when its pending
assembles, and the whole loop sits in a `try…finally` that frees every frame's `Owned` on the way
out. Each free takes the pointer OFF the frame first: a frame still holding it would hand the
`finally` the same tree a second time.

**A worklist has to grow, and that made the FREE path able to raise** — something the recursive
version, whatever else was wrong with it, could not do. Between taking a list off its owner and
freeing it, nothing owns it, so a raise in the middle of a node would strand what was already
detached. The review round found exactly that, and it is closed the way §5.11's attach-first
invariant was: the worklist grows **once per node, before that node is touched**, so the only
allocation in the walk runs while the node is still whole and a node is untouched or fully
detached, never half; and a handler frees what is left — everything still queued is detached and
owned by nothing else, and the list being drained owns exactly the nodes it has not reached. That
handler frees recursively, which is the one thing this procedure exists to avoid, and is the right
trade only there: the heap has already refused, and a deep free that might overflow beats leaking
the tree. Only a failing allocation exercises any of this, so it is checked by reading — the same
class of defect, found the same way, as the parser's.

**Where it stops now.** The stack is out of the equation; what remains is the parse's own
quadratic TIME, already a backlog item.

| chain, render + free, iterative build | 50 000 | 60 000 | 100 000 | 200 000 |
|---|---|---|---|---|
| enumeration | ok, 7.0 s | ok, 8.9 s | ok, 26 s | ok, 129 s |
| conditional | ok, 7.4 s | ok, 11 s | ok, 49 s | ok, 234 s |
| permutation | ok, 8.7 s | ok, 13 s | ok, 37 s | ok, 226 s |
| splice `[<sep=%s1%>[<sep=%s2%>…]]` | ok, 126 s | ok, 196 s | ok, 578 s | not run |
| **free only**, never rendered | ok, 6.8 s | ok, 8.6 s | ok, 25 s | ok, 122 s |

The recursive build raises `EStackOverflow` at 60 000 on the first row and on the last, and does
not survive the last one — a stack overflow inside a destructor takes the process with it. The
splice row at 200 000 was not run: its clock is the parse's quadratic, not the walk's depth, and
600 s at 100 000 buys nothing the 100 000 row has not already said.

**Memory was the measurement that could have gone the other way**, since the frame array, each
frame's buffer and the retained `PendDone` strings are new memory held for the depth of the tree —
so the peak was sampled rather than the clock (§5.13's lesson). It did not go the other way, but
the honest answer is smaller than the first one written here, and **the instrument is the reason**.

Peak **working set** is not a property of the program: it is what the OS keeps resident, so it
moves with the machine's memory pressure. A first pass sampled it once per shape and recorded
39 → 32 MB for an enumeration chain and 47 → 37 MB for a permutation chain. Neither number
reproduced: the same enumeration chain measured 42.5, 42.5 and 40.2 MB on the recursive build in
three consecutive runs, and one run of the same command reported 27. Peak **private bytes** (commit
charge) is the stable one. Both, at 50 000 levels, three runs each:

| chain | recursive, private | iterative, private | recursive, working set | iterative, working set |
|---|---|---|---|---|
| enumeration | 21.5 / 21.4 / 34.7 | 21.8 / 21.2 / 23.2 | 42.5 / 42.5 / 40.2 | 31.7 / 31.7 / 31.9 |
| conditional | 21.8 / 21.5 / 21.7 | 22.5 / 22.4 / 22.0 | 27.1 / 34.8 / 27.0 | 31.7 / 31.6 / 27.3 |
| permutation | **36.0 / 36.0 / 36.0** | **31.2 / 31.2 / 31.2** | 46.9 / 46.9 / 46.9 | 36.5 / 36.5 / 36.5 |

So: a **permutation** chain costs reproducibly less on both instruments — 36.0 → 31.2 MB committed,
identical to the tenth of a megabyte across three runs, because a permutation's elements were held
in Pascal frames and are now `PendDone` strings on one frame. An **enumeration** chain commits the
same and keeps a third fewer pages resident. A **conditional** chain shows no change worth stating,
and its working-set column is noise in both builds. The 200 000-level enumeration holds 103 MB.

**The general claim "peak memory fell" is therefore not supported for every shape** — it is
supported for the permutation, and for nothing else beyond residency. A single sample of peak
working set is not evidence; if a claim about memory is worth making, it is worth three runs of
commit charge.

**Verified as a pure refactor, which is the only acceptable result for it.** 180 000 generated
templates × 6 configurations (first / last / **sequence** RNG × post-process off and on) =
1 080 000 renders, **byte-identical** to the previous build on all four seeds, corpus generated
once and fed to both. Four control mutants say the zero is not vacuous, each differing of 45 000:
a one-option enumeration that draws again (18 224), a permutation size pick that always draws
(22 241), elements rendered right-to-left (26 798), and an enumeration that descends into EVERY
option and picks afterwards (11 861) — the last one is the control for pick-before-descend, the
property this section states first, and its output is identical wherever an unpicked option
contains no construct. Gates: 614 local checks and 102 GSA checks in both builds, `PASS=329
FAIL=0 SKIP=4`, `-Sew` clean.

**The suites pin the ROUTE at 5 000 levels, not the ceiling** — a 200 000-level render costs
minutes and the local suite runs twice on every push. Four checks cover it: an enumeration and a
conditional chain rendered, a chain built and freed in an UNPICKED branch, and the two chains this
change made reachable at all (a permutation chain, and a splice chain of nested separators).

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
5. **A class is decided by the ORIGIN's regex dialect, then spelled as the reference spells
   it.** PHP compiles a `/u` pattern with PCRE2_UCP (`\s`, `\d`, `\w`, `\b` Unicode) and does
   not fold a property escape under `/i`; a pattern without `/u` is ASCII. JavaScript agrees
   with neither, which is how the reference, and this port after it, read the post-process as
   ASCII and folded (§5.12). This hazard used to say "use the folded predicates for the `/giu/`
   rules" — a faithful reading of the JavaScript and a wrong one of the contract. Only the
   single-abbreviation lookbehind still reads letters folded, because the reference still
   writes it `giu`. Check the PHP flags before porting any pattern.
6. **Unbounded nesting must be iterative.** A recursive walk dies on deep input the
   reference handles — the lesson the Python port already paid for. `ParseSequence` (§5.11),
   `RenderNodes` and `FreeNodeTree` (§5.14) are all explicit walks now; the walk to watch is
   whichever one is written next, and the three recursions left in the render (§5.14) are
   bounded by a depth cap each. **A destructor is a walk too** — `TObjectList<T>` with
   `OwnsObjects` recursing through owned children cost seven or eight frames per level and
   overflowed at the same depth the render did, which is why freeing a tree goes through
   `FreeNodeTree` at every site rather than through `Free`.

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
