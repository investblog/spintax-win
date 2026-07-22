# spintax-win

An Object Pascal port of the reference spintax engine, held to the same shared
golden-fixture corpus as the TypeScript, PHP, and Python implementations. Zero
external dependencies. Free Pascal 3.2.2+, `{$mode delphi}`.

**Target: Free Pascal 3.2.2+.** The whole golden corpus passes — `PASS=164 FAIL=0
SKIP=4`, the 4 skips being `kind:rng`, engine-private by design.

The source also compiles unchanged under a UTF-16 Object Pascal compiler: `string`
is UTF-8 bytes here and UTF-16 code units there, and everything that reasons about
characters goes through the code-point helpers rather than indexing text. That
portability is **kept, not maintained** — it is not a supported platform and no
build is gated on it. It earned its place by finding real defects (see below); it
is not a promise.

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
| render-semantics       | 59    | 59     | plurals, conditionals, permutations, variables, set/def |
| render-deterministic   | 6     | 6      | variable substitution, enumeration selection |
| render-rng-selection   | 10    | 10     | selection semantics under injected RNG |
| neutralize             | 8     | 8      | T2 shielding round-trip               |
| extract                | 2     | 2      | ref / set / def / include enumeration |
| validate               | 40    | 40     | bracket/directive/permutation/plural/variable diagnostics |
| render-postprocess     | 39    | 39     | full 12-step pipeline                 |

Totals: **`PASS=164 FAIL=0 SKIP=4`** over 168 cases. Only `kind:rng` render cases
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
    tests/corpus_runner.dpr   golden-corpus conformance runner (reports; always exits 0)
    tests/SpxJson.pas         JSON facade: fpjson, or System.JSON on a UTF-16 compiler
    tests/check-corpus.sh     the gate: runs the runner, diffs against the baseline
    tests/known-failures.txt  expected-failure baseline (currently empty)
    tests/local_tests.dpr     assertions no corpus fixture can express
    src/Spintax.Unicode.inc   generated Unicode tables (scripts/gen-unicode-tables.cjs)
    examples/demo.lpr         command-line render demo
    docs/spec-pascal-port.md  the governing parity contract

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
    function SpValidate(const Src, Locale: string; KnownIncludes: TStringList): TSpDiagList;
    function NormalizeBaseLang(const Locale: string): string;
    function PluralArity(const BaseLang: string): Integer;

`SpValidate` returns a list of `TSpDiag` (code + severity). A template is invalid
if any diagnostic has severity `error`; that is the verdict an editor or an
LLM-repair loop keys off. `TSpContext` carries the runtime variable map, locale, a `PostProcess` flag, and
an injected `TSpRng`. The RNG seam ships with `TFirstRng`, `TLastRng`,
`TSequenceRng`, and a seeded `TMulberry32Rng`.

## License

MIT. See LICENSE.
