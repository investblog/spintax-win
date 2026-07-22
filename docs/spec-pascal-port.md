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

Compiles under Free Pascal 3.2.2+ and Delphi 13, in `{$mode delphi}`, with the same
measured corpus result on both (§4). MIT.

## 2. Position in the family

| repo | package | role |
|------|---------|------|
| `spintax-js` | `@spintax/core` (TS, MIT) | **reference engine + home of the golden corpus** |
| `spintax-php` | `spintax/core` (MIT) | sibling port |
| `spintax-py` | `spintax-core` (MIT) | sibling port |
| `spintax` | WordPress plugin (**GPL**) | origin engine — behavior reference only |
| **`spintax-win`** | `Spintax.Core` (DPM) | **this port** |

**Licence boundary.** The PHP plugin is GPL. Transcribing it would pull GPL into an MIT
package. Reimplement from the behavior contract plus the corpus. `@spintax/core` is our
own MIT code and IS a legitimate reference — mirror its *behavior*, never its TypeScript.

### Why Delphi is a target at all

Delphi support exists for **one** purpose: so the **GSA SER** development team can port
this engine into their codebase without friction. It is not aimed at Delphi consumers
installing a package, and the project will **not** buy Delphi licences.

Three consequences follow, and they explain choices that would otherwise look odd:

1. **Source portability outranks distribution.** What matters is that `src/Spintax.pas`
   compiles clean under Delphi and reads plainly. That is why the file stays free of
   FPC-only constructs and why `{$IFDEF UNICODE}` branches exist wherever a specific code
   point is spelled.
2. **The Delphi check is manual, permanently.** No available licence grants `dcc32`, and
   none will be bought, so CI can never gate Delphi. The parity claim is therefore dated
   rather than continuously enforced, and every string-width-sensitive change needs a
   rebuild in the IDE. **Delphi 12 Starter is installed permanently** and its IDE compiles
   Win32, so this survives the Architect trial expiring.
3. **DPM packaging is optional, not load-bearing.** `Spintax.Core.dspec` targets a package
   manager nobody in this use case needs; treat it as a nice-to-have, not a release gate.

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
(168 cases total):

| fixture file | cases | passing |
|---|---|---|
| render-semantics | 59 | 59 |
| validate | 40 | 40 |
| render-rng-selection | 10 | 10 |
| neutralize | 8 | 8 |
| render-deterministic | 6 | 6 |
| extract | 2 | 2 |
| render-rng | 4 | — skipped by design (within-engine reproducibility only) |
| **render-postprocess** | **39** | **39** |

**`PASS=164 FAIL=0 SKIP=4`** — the whole corpus, the 4 skips being `kind:rng` render
cases, which are engine-private by design.

**Delphi 13 Florence produces the identical result** — `164/0/4`, measured 2026-07-22
with the full post-process pipeline (`tests/delphi/RESULTS.md`). The runner is one source
for both compilers; `tests/SpxJson.pas` is the only place their APIs differ.

The claim is dated on purpose: no licence here grants `dcc32`, so the Delphi run is a
manual rebuild that CI cannot gate. Treat it as stale after any engine change. What CI
*can* now cover is the Delphi-Debug bug class: `build.sh` compiles the local suite a second
time with `-Co -Cr`, which reproduces Delphi's overflow and range checks under FPC.

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

`SpValidate` returns `TSpDiagList` (`TList<TSpDiag>`, code + severity). Invalid iff any
diagnostic is severity `error` — that is the verdict an editor or an LLM-repair loop
keys off.

`KnownVariables` names what the **host** will supply at render time, mirroring the
reference's `ValidateOptions.knownVariables`: a reference to one is not "undefined", so the
`variable.undefined` warning is suppressed for it. Matching is case-insensitive. It only
ever silences a **warning** — an unresolved `%var%` has never made a template invalid and
must not start to, or a host rendering with runtime variables would see its own templates
called broken.

## 6. Trust model

`SpNeutralize` is a utility the **host** applies to data-derived (T2) input. The engine
must NOT auto-shield author-controlled (T1) values. Sentinels U+E000–E005 are the engine's
reserved range; the safety restore is **mandatory** and survives `PostProcess=False`.

## 7. Port hazards specific to Object Pascal

1. **`{$mode delphi}` is the contract.** Anything needing `{$mode objfpc}` or FPC-only RTL
   is a portability break even with a green corpus. The directive itself must stay wrapped
   in `{$IFDEF FPC}` — Delphi rejects `{$MODE}` as an invalid compiler directive.
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
   Writing its UTF-8 bytes is not portable: under Delphi those bytes are decoded through the
   machine's ANSI codepage, so the result varies by machine.
3. **Warnings must be fatal** (`-Sew -vm4046`) — FPC accepts an uninitialised function
   result or a shadowed variable with a mere warning, and those are what a port produces.
   `-vm4046` masks one warning raised by FPC's own generics RTL and nothing else.
4. **Delphi's Debug build enables overflow and range checks; FPC's default build does
   not.** Arithmetic that wraps on purpose — the mulberry32 mixer — raises `EIntOverflow`
   there and passes silently here. Suppress checks around such code with `$IFOPT`, so a
   host that builds with checks on keeps them everywhere else. `build.sh` compiles the
   local suite a second time with `-Co -Cr` to catch this without a Delphi.
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
