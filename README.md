# spintax-win

An Object Pascal (Delphi-mode) port of the reference spintax engine, held to the
same shared golden-fixture corpus as the TypeScript, PHP, and Python
implementations. Zero external dependencies. Compiles under Free Pascal 3.2.2 in
`{$mode delphi}`.

**Delphi status: at parity, measured 2026-07-22.** The golden corpus runs under
Delphi 13 Florence and Free Pascal 3.2.2 with identical results — `PASS=143
FAIL=21 SKIP=4`, and the failing sets match case for case, not merely in total.
The local suite (`31` assertions on surfaces no fixture can express) passes on
both, and the Delphi build is clean: 0 errors, 0 warnings, 0 hints. Measurements
in [tests/delphi/RESULTS.md](tests/delphi/RESULTS.md).

The claim carries a date because it cannot be automated: no licence available for
this project grants Delphi's command-line compiler, so the Delphi run is a manual
rebuild and **CI cannot gate it**. Treat it as stale after any engine change.

Two defects had to be fixed to get there, and **neither was findable under FPC
alone**: the sentinel literals were UTF-8 bytes that a UTF-16 `string` decoded
through the machine's ANSI codepage, and `#def` values were rolled in hash-map
order, which FPC happened to get right. See
[docs/decisions/0003](docs/decisions/0003-delphi-compatibility-audit.md).

Caveat worth knowing before you rely on it: Delphi's command-line compiler is not
available under this project's licences, so the Delphi run is manual and **cannot
be gated in CI**. FPC is gated on every push; Delphi is a dated manual check.

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
| render-postprocess     | 39    | 18     | cosmetic stage is minimal (see Scope) |

Totals: `PASS=143 FAIL=21 SKIP=4` over 168 cases, measured on FPC 3.2.2 /
i386-win32. The full deterministic semantic gate and the static validator pass.
Only `kind:rng` render cases are skipped by the runner; they assert within-engine
reproducibility, not a cross-engine exact output, so they are engine-private by
design.

**All 21 failures are in `render-postprocess`** and nowhere else. They are
enumerated in `tests/known-failures.txt` and gated by `tests/check-corpus.sh`:
a new failure fails the build, and one of the listed cases starting to pass also
fails the build until its line is removed. `corpus_runner` itself only reports —
it exits 0 either way — so the gate is the script, not the runner.

## Scope and known remainder

Implemented and fixture-verified: parse and render for enumerations,
permutations (with `<config>` for `minsize`/`maxsize`/`sep`/`lastsep` and
per-element separators), scoped variables with recursive value expansion,
`#set` macros and `#def` definitions, value-driven conditionals `{?VAR?a|b}`
and `{?!VAR?a}`, locale-aware plurals for the Slavic three-form family
(ru/uk/be, sr/hr/bs) and the two-form default, `neutralize` / safety-restore,
`extract`, and the static `validate` (bracket balance, directive shape and
duplicate names, permutation config keys, plural nesting and arity, variable
self- and circular-reference, unknown include targets).

Deliberately minimal in this port:

- Cosmetic post-process. Only ASCII space collapsing, punctuation spacing, and
  first-letter capitalization are ported. The full stage in the reference also
  shields URLs, emails, domains, decimals, and abbreviations, handles Spanish
  sentence openers, and capitalizes after sentence boundaries and block tags
  through Unicode. That accounts for the render-postprocess remainder above.
- Cross-engine RNG-sequence parity. This is a non-goal in the reference as well;
  seeded PRNG output is reproducible within an engine, not identical across
  engines. The deterministic fixtures use an injected RNG strategy, so they do
  not depend on it.

## Build and test

Requires Free Pascal 3.2.2 or newer.

    ./build.sh
    ./tests/corpus_runner /path/to/conformance/fixtures
    ./examples/demo '[<sep=", ">fast|cheap|reliable] hosting'
    ./examples/demo '{plural 5: товар|товара|товаров}' ru

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
    tests/SpxJson.pas         JSON facade: fpjson under FPC, System.JSON under Delphi
    tests/check-corpus.sh     the gate: runs the runner, diffs against the baseline
    tests/known-failures.txt  the 21 known cosmetic failures, one per line
    examples/demo.lpr         command-line render demo
    Spintax.Core.dspec        DPM package spec
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
`examples/demo.lpr` do it. Under Delphi the question does not arise: `string` is
UTF-16 and the engine's sentinel literals branch on `UNICODE` accordingly.

This is not theoretical — it is what made the Linux CI leg fail while Windows
passed, and it took a byte dump to see, because every log renders the corruption
as `?`.

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
