# spintax-win

[![CI](https://github.com/investblog/spintax-win/actions/workflows/ci.yml/badge.svg)](https://github.com/investblog/spintax-win/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A **[Spintax](https://spintax.net) engine** for Object Pascal -- parse, render,
validate, extract and neutralize spintax templates. MIT, zero dependencies,
Free Pascal 3.2.2+ in `{$mode delphi}`.

The fourth engine in the Spintax family, and an **independent implementation** --
not a transcription of the others. It is held to the same behaviour contract by a
**shared golden corpus** of language-neutral fixtures, the same one that gates the
TypeScript, PHP and Python engines: **200 of its 204 cases pass and none fail**. The
other 4 are skipped by design -- `kind:rng`, which assert within-engine reproducibility
rather than a cross-engine output.

## Use

```pascal
uses Spintax;

var
  ctx: TSpContext;
begin
  { An FPC host must declare UTF-8 once -- see "Encoding" below. }
  DefaultSystemCodePage := CP_UTF8;

  ctx := Default(TSpContext);
  ctx.PostProcess := True;          { cosmetic stage; off in a zeroed record }

  SpRender('{Hello|Hi} there!', ctx);
  // "Hello there!" or "Hi there!"

  SpRender('[<sep=", ">fast|cheap|good] hosting', ctx);
  // the three in some order: "Good, cheap, fast hosting"

  SpRender('{hello|hi}. {world|earth}', ctx);
  // "Hello. World" or "Hi. World" -- either way the post-process
  // capitalizes both sentence starts, though the options are lower-case
end;
```

Leave `ctx.Rng` nil for non-deterministic output, or inject a `TSpRng` -- the
seam ships `TFirstRng`, `TLastRng`, `TSequenceRng` and a seeded `TMulberry32Rng`
-- when you want reproducibility.

## The family

- **TypeScript / JavaScript:** [`@spintax/core`](https://www.npmjs.com/package/@spintax/core)
  ([source](https://github.com/investblog/spintax-js)) -- the reference engine, and the
  home of the golden corpus.
- **PHP:** [`spintax/core`](https://packagist.org/packages/spintax/core)
  ([source](https://github.com/investblog/spintax-php)).
- **Python:** [`spintax-core`](https://pypi.org/project/spintax-core/)
  ([source](https://github.com/investblog/spintax-py)).
- **WordPress:** [the original plugin](https://github.com/investblog/spintax) -- the origin
  engine, GPL.

The engines are independent implementations held together by the shared corpus, not
ports of one another's code.

## Portability beyond FPC

The source also compiles unchanged under a UTF-16 Object Pascal compiler: `string`
is UTF-8 bytes here and UTF-16 code units there, and everything that reasons about
characters goes through the code-point helpers instead of indexing text.

That portability is **kept, not maintained** -- it is not a supported platform and
nothing is gated on it. It stays because it earned its place: building the same
source with a second compiler found defects the corpus could not, and two of them
were bugs in the Free Pascal build as well.

The engine implements the spintax.net superset: not just flat `{a|b|c}`
enumerations, but permutations, scoped variables, value-driven conditionals, and
locale-aware plurals. Syntax reference: https://spintax.net

## Why this exists

Flat spintax (`{a|b|c}`) is a coin flip per brace. The superset adds structure
that a single template can carry:

    flat:      {Fast|Cheap|Reliable} {hosting|servers} for {business|teams}
    superset:  [<sep=", ">fast|cheap|reliable] %product% for {?enterprise?teams|everyone}

The permutation `[ ... ]` selects and orders a subset with a configurable
separator; `%product%` is a scoped variable; `{? ... ?}` branches on whether a
variable is set. One authored template covers a far larger, better-controlled
output space than the same length of flat spintax, and it spins locally at zero
marginal cost.

This repository is a working, fixture-proven reference for that engine in Object
Pascal. It is not affiliated with any content tool; the syntax is the open
standard documented at spintax.net.

## Conformance

The runner in `tests/` loads the shared golden corpus (the exact JSON fixtures
the TypeScript and PHP suites consume) and asserts the deterministic
cross-engine gate. Measured on this port:

| corpus file            | cases | passed | note                                  |
|------------------------|-------|--------|---------------------------------------|
| render-semantics       | 65    | 65     | plurals, conditionals, permutations, variables, set/def |
| render-deterministic   | 16    | 16     | variable substitution, enumeration selection |
| render-rng-selection   | 10    | 10     | selection semantics under injected RNG |
| neutralize             | 8     | 8      | T2 shielding round-trip               |
| extract                | 12    | 12     | ref / set / def / include enumeration |
| validate               | 46    | 46     | bracket/directive/permutation/plural/variable diagnostics |
| render-postprocess     | 43    | 43     | full 12-step pipeline                 |

Totals: **`PASS=200 FAIL=0 SKIP=4`** over 204 cases. Only `kind:rng` render cases
are skipped; they assert within-engine reproducibility, not a cross-engine exact
output, so they are engine-private by design.

`tests/known-failures.txt` is now empty, and `tests/check-corpus.sh` keeps it
honest in both directions: any failure fails the build, and a case that starts
passing must be recorded rather than absorbed. `corpus_runner` itself only
reports — it exits 0 either way — so the gate is the script, not the runner.

## Scope

Implemented and fixture-verified: parse and render for enumerations,
permutations (with `<config>` for `minsize`/`maxsize`/`sep`/`lastsep` and
per-element separators), scoped variables with recursive value expansion,
`#set` macros and `#def` definitions, value-driven conditionals `{?VAR?a|b}`
and `{?!VAR?a}`, locale-aware plurals for the Slavic three-form family
(ru/uk/be, sr/hr/bs) and the two-form default, `neutralize` / safety-restore,
`extract`, and the static `validate` (bracket balance, directive shape and
duplicate names, permutation config keys, plural nesting and arity, variable
self- and circular-reference, unknown include targets).

Deliberately out of scope:

- Cross-engine RNG-sequence parity. This is a non-goal in the reference as well;
  seeded PRNG output is reproducible within an engine, not identical across
  engines. The deterministic fixtures use an injected RNG strategy, so they do
  not depend on it.

## Build and test

Requires Free Pascal 3.2.2 or newer.

    ./build.sh
    ./tests/corpus_runner /path/to/conformance/fixtures
    ./tests/local_tests
    ./tests/local_tests_checked
    ./examples/demo '{hello|hi}. {world|earth}'
    ./examples/demo '[<sep=X>fast|cheap|reliable] hosting'
    ./examples/demo '{plural 5: товар|товара|товаров}' ru

Note on quoting: a template containing double quotes -- `[<sep=", ">...]` -- does not
survive Windows command-line argument parsing, which turns the quotes into backslashes
before the program ever sees them. That is the shell, not the engine. Use a config
without quotes on the command line, or pass the template from a file.

If no fixtures path is passed, the runner looks for a local checkout of the
reference corpus. Point it at the `packages/conformance/fixtures` directory of
the reference repository — the corpus is checked out, never vendored here, so
that the contract cannot drift from a stale copy.

The golden corpus is the acceptance suite, not a smoke test: the `pre-push` hook
runs the build and the runner, and refuses to pass when `SPINTAX_FIXTURES` is
unset. A runner with no fixtures reports success over zero cases, which is worse
than a failure.

## Layout

    src/Spintax.pas           the engine (unit Spintax)
    src/Spintax.Gsa.pas       optional GSA SER dialect front end (unit Spintax.Gsa)
    tests/corpus_runner.dpr   golden-corpus conformance runner (reports; always exits 0)
    tests/SpxJson.pas         JSON facade: fpjson, or System.JSON on a UTF-16 compiler
    tests/check-corpus.sh     the gate: runs the runner, diffs against the baseline
    tests/known-failures.txt  expected-failure baseline (currently empty)
    tests/local_tests.dpr     assertions no corpus fixture can express
    tests/gsa_tests.dpr       assertions for the GSA front end
    src/Spintax.Unicode.inc   generated Unicode tables (scripts/gen-unicode-tables.cjs)
    examples/demo.lpr         command-line render demo
    docs/spec-pascal-port.md  the governing parity contract
    docs/decisions/           the architecture decision records

## Encoding: a host responsibility

`string` carries **raw UTF-8 bytes**. The engine never converts, and it must not be
handed anything else.

Under FPC that is not automatic. FPC converts to `DefaultSystemCodePage` at
boundaries, and that default follows the locale — under `LANG=C` it is ASCII, so
every non-ASCII character silently becomes `'?'` *before the engine sees it*. An
FPC host must declare UTF-8 once at start-up:

    DefaultSystemCodePage := CP_UTF8;

A library cannot set this for its callers. Both `tests/corpus_runner.dpr` and
`examples/demo.lpr` do it. On a UTF-16 compiler the question does not arise, and
the engine's sentinel literals branch on `UNICODE` accordingly.

This is not theoretical — it is what made the Linux CI leg fail while Windows
passed, and it took a byte dump to see, because every log renders the corruption
as `?`.

## One API-shape difference from the reference

`Default(TSpContext)` leaves `PostProcess` **False**, while the reference defaults
`postProcess: true`. A host that fills the record itself and never sets the flag
therefore gets no cosmetic stage at all, silently.

This is deliberate — a Pascal record has no notion of "unset", so `False` is what
zeroed memory means and inventing a tri-state to mimic a JS default would be worse.
**Set it explicitly.** Both `tests/corpus_runner.dpr` and `examples/demo.lpr` do.

## Public API

    function SpRender(const Template: string; const Ctx: TSpContext): string;
    function SpNeutralize(const Value: string): string;
    function SpSafetyRestore(const Text: string): string;
    function SpStripSentinels(const Text: string): string;
    function SpExtract(const Src: string): TExtractResult;
    function SpExtractDirectives(const Src: string): TSpDirectiveList;
    function SpValidate(const Src, Locale: string; KnownIncludes: TStringList): TSpDiagList;
    TSpIncludeResolver = class                      // TSpContext.IncludeResolver
      function Resolve(const Ref: string; out Text: string): Boolean; virtual; abstract;
    end;
    function NormalizeBaseLang(const Locale: string): string;
    function PluralArity(const BaseLang: string): Integer;

`SpValidate` returns a list of `TSpDiag` (code + severity). A template is invalid
if any diagnostic has severity `error`; that is the verdict an editor or an
LLM-repair loop keys off.

`SpExtract` answers *which* names and targets a template uses — deduplicated, no
values, no positions, which is what a validator needs. `SpExtractDirectives`
answers *where*: every `#set` / `#def` / `#include` occurrence in source order,
with its span in the original text, its value and the line the renderer consumed.
That is the difference between validating a template and editing one — a host
substituting an `#include` by name cannot tell a commented-out occurrence from a
live one, because the target list holds a single entry for both. Both read the
source as written; `SpRender` alone deletes reserved sentinels first, so raw
U+E000–U+E005 in author markup makes them disagree — as it does in every engine
of the family.

`TSpContext` carries the runtime variable map, locale, a `PostProcess` flag, an
injected `TSpRng`, and an optional `TSpIncludeResolver`. The RNG seam ships with
`TFirstRng`, `TLastRng`, `TSequenceRng`, and a seeded `TMulberry32Rng`.

`#include` is resolved at render time **only if you supply a resolver** — subclass
`TSpIncludeResolver` and return `False` for a target you do not have. Left `nil`,
the directive stays in the output verbatim, which is what the reference does with
no resolver either. The semantics are the family's, and they are not what splicing
the child's source into the document would give: the child is parsed and rendered
**on its own** and its *output* substituted, it inherits the runtime context but
**not** the parent's `#set`/`#def`, and an unknown target, a cycle, or a chain
deeper than `MaxIncludeDepth` (`0` → `SP_DEFAULT_INCLUDE_DEPTH` = 20) resolves to
an empty string rather than an error. The cosmetic post-process and the sentinel
restore run once, over the assembled document.

## Optional: running GSA SER templates

`src/Spintax.Gsa.pas` is a front end, not part of the engine: it rewrites a
[GSA Search Engine Ranker](https://docu.gsa-online.de/search_engine_ranker/macro_guide)
template into the syntax above, so an existing SER project renders here unchanged. The
engine gains no GSA syntax — the family's contract is the corpus, and a dialect belongs
beside it. It has its own suite (`tests/gsa_tests.dpr`) and is not gated by the corpus.

```pascal
uses Spintax, Spintax.Gsa;

macros := TStrMap.Create;              { both are the caller's to own and free }
unsup  := TStringList.Create;
tmpl   := SpGsaToSpintax(gsaTemplate, macros, unsup);
ctx.Vars := macros;                    { required -- see below }
SpRender(tmpl, ctx);
```

- `~{a|b|c}` → `[a|b|c]`. The guide defines the tilde form as *all* variations in a
  *random* order, which is this family's permutation exactly.
- Spintags as the guide writes them — `{#T1 a|#T2 b}` … `{#T1 c|#T2 d}`, a tag on every
  option, correlated by label. Each group becomes one `#def` plus conditionals, so the
  blocks stay paired instead of choosing independently. Confirmed against SER itself:
  eight copies of one tagged block in a single article all return the same branch, where
  eight untagged copies do not.
- `#file[...]`, `#file_links[...]`, `#openai[...]`, `%related_url_link[...]%` and their
  siblings → `%…mN%`, with the macro text handed back in `macros`. This is not cosmetic:
  `[` opens a permutation here, so an unconverted `#file[list.txt,1,S]` renders as
  `#filelist.txt,1,S`, and a macro carrying a `|` gets its arguments **shuffled**. It
  cannot be repaired inside the template, because `SpRender` strips reserved sentinels
  from a template before parsing — hence the map.

It also lifts out the GSA text that this engine would otherwise read as *its* syntax. GSA
has no permutation and no comment form, so `[b]bold[/b]`, `[10|20]`, a `#top` fragment URL
and a line beginning `#set` are ordinary characters there — and, left alone, this engine
eats the brackets, shuffles the bracketed list, swallows the rest of the document as an
unterminated comment, and consumes the directive line. Those characters are lifted the same
way a macro is; identical ones share one variable.

**`macros` is not optional.** Ignore it and every lifted construct renders as a visible
`%…m1%` instead of its real text. That is deliberate: the alternative failure mode is
output that still looks like a macro and is not one. Merge it into `ctx.Vars` rather than
the other way round — a host entry of the same name would shadow a lifted one.

**`unsup` is what the converter refused.** `{#.de …|#.com …}` selects on the target URL's
domain — host context, not a spin. So is a block where only some options carry a tag: SER
does something real with those, but measurably not what its own feature request described,
and nothing the guide documents (see the ADR). Those blocks are lifted out and reported as
`name=original text`; left in the
template they would not be "left alone", they would be rendered as an ordinary spin, one
random branch with the tag still in it. Rendered as they are, they reproduce the source
exactly; a host that wants to resolve one overrides that variable.

See [ADR 0005](docs/decisions/0005-gsa-dialect-front-end.md).

## License

MIT. See LICENSE.
