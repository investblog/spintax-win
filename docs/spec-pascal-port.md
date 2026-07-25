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
(172 cases total):

| fixture file | cases | passing |
|---|---|---|
| render-semantics | 59 | 59 |
| validate | 40 | 40 |
| render-rng-selection | 10 | 10 |
| neutralize | 8 | 8 |
| render-deterministic | 6 | 6 |
| extract | 2 | 2 |
| render-rng | 4 | — skipped by design (within-engine reproducibility only) |
| **render-postprocess** | **43** | **43** |

**`PASS=168 FAIL=0 SKIP=4`** — the whole corpus, the 4 skips being `kind:rng` render
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

This **reverses** [`decisions/0002`](decisions/0002-postprocess-remainder.md), which
recorded the minimal stage as a deliberate scope decision.

## 5. Public API

```pascal
function SpRender(const Template: string; const Ctx: TSpContext): string;
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
varied. `SpExtract` and `SpValidate` are now the expensive pair on a directive-heavy document
(`SpExtract` 281 ms against 5 ms at 1600 directives) — a host calling them per keystroke
should debounce.

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
must do the same, NBSP included.

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

## 9. Open questions

Tracked in [`TODO.md`](TODO.md). Nothing here blocks use of the engine as it stands.
