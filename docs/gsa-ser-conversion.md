---
type: reference
status: active
tags: [gsa, ser, dialect, converter, interop, integration]
project: spintax-win
---

# Converting a GSA SER template — the complete mapping

What `src/Spintax.Gsa.pas` does to every construct in
[GSA Search Engine Ranker's macro guide](https://docu.gsa-online.de/search_engine_ranker/macro_guide),
written for someone wiring this engine into SER and needing to know exactly what the code
decides on their behalf.

The decision behind the front end — why a dialect is converted rather than added to the
engine — is [ADR 0005](decisions/0005-gsa-dialect-front-end.md). This file is the mapping
itself.

**`Spintax.Gsa` is not the engine.** It is an optional unit; `Spintax` does not reference
it, the golden corpus does not gate it, and it adds nothing to the engine's public surface.
Nothing in it can change what `SpRender` produces for a template that never went through it.

---

## 1. The rule everything else follows

> **A conversion may never leave the engine free to render a GSA construct as something
> else.**

Anything the converter does not understand is **lifted out of the template** into a
variable, not left in place. The first version left unconvertible blocks alone — and
`SpRender` then read `{#.de Hallo|#.com Hello}` as an ordinary spin and printed
`#.de Hallo`: one random branch, tag included. "Untouched in the template" and "untouched in
the output" are different claims, and only the second one matters.

A lifted construct renders back as the author's own text, byte for byte. A host that wants
to resolve one overrides that variable.

## 2. The call

```pascal
uses Spintax, Spintax.Gsa;

macros := TStrMap.Create;                 { both are the caller's to own and free }
unsup  := TStringList.Create;
tmpl   := SpGsaToSpintax(gsaTemplate, macros, unsup);

ctx.Vars        := macros;                { REQUIRED — see below }
ctx.PostProcess := False;                 { REQUIRED for SER-bound text — see below }
output := SpRender(tmpl, ctx);
```

Textual only: no rendering, no RNG, no I/O. The result is a template, and every choice it
describes is still the engine's to make at render time.

| parameter | contract |
|---|---|
| `Src` | the SER template, as the author wrote it |
| `MacroVars` | must not be nil. One entry per lifted construct. **Merge it into `ctx.Vars`** — a host entry of the same name would otherwise shadow a lifted one |
| `Unsupported` | must not be nil. `name=original text` for every block the converter refused. **Empty means everything was translated** |
| result | the converted template |

**Ignoring `MacroVars` is a visible failure, by design.** Every lifted construct then
renders as `%__gsa_m1%` — obviously wrong, rather than a macro quietly missing its brackets.
That was the deciding argument over anything that fails silently.

**`PostProcess=False` for text going back to SER.** The cosmetic stage runs *before* the
sentinel restore, so it both retypesets the author's GSA prose and reaches inside a rescued
macro: `a #file_links[names.dat,2,S] b` comes out as `A #file_links[names.dat,2, S] b`. That
ordering is the whole family's contract, pinned by corpus fixtures, not a defect here.

## 3. Pipeline

Four passes, in this order. Order matters: macros leave before anything can shuffle their
arguments, and literals leave before the tag walk can mistake one for syntax.

| # | pass | what it removes from the engine's reach |
|---|---|---|
| 1 | `ExtractMacros` | bracketed GSA macros |
| 2 | `ProtectLiterals` | GSA text this engine would read as *its* syntax |
| 3 | `ConvertTilde` | `~{…}` → `[…]` |
| 4 | `WalkTags` | spintag blocks → `#def` chains, or a refusal |

---

## 4. Spin forms

| GSA | converts to | behaviour |
|---|---|---|
| `{a\|b\|c}` | `{a\|b\|c}` (unchanged) | pick one at random. The syntax is already identical |
| `~{a\|b\|c}` | `[a\|b\|c]` | **all** options, in a random order, joined by one space |
| `~{a\|~{b\|c}}` | `[a\|[b\|c]]` | nesting is handled recursively |

The guide defines the tilde form as *"all variations are used but in a random order"*,
which is this family's permutation exactly — `[a|b|c]` reproduces the guide's own worked
example, separator included. (The feature request that started this work described it as
emitting options *in order*; the guide is what the code follows.)

## 5. Spintags

### The form that converts — a tag on every option, correlated by label

```
{#T1 friend|#T2 mate}  …  {#T1 see you|#T2 later}
```
becomes
```
{?__gsa_g1_1?friend|mate}  …  {?__gsa_g1_1?see you|later}
#def %__gsa_g1_1% = {x|}
```

Blocks are grouped by their **set of tags**; every block of a group tests the same
definitions in the same canonical order, so the group moves together. A group of *n*
branches gets *n−1* definitions, the *i*-th non-empty with probability 1/(n−i+1), which
makes the chain uniform over all *n*.

This works because **`#def` resolves once per render and holds** — which is precisely "a
choice made once and reused". A group consisting of a single block needs no correlation and
is written as the plain enumeration it already is.

Generated definitions are appended at the end of the converted template. That is legal
wherever they sit: `#def` is a document-level definition, not a statement executed in place.

Three branches, two blocks, measured:

```
{#A a|#B b|#C c} and {#A x|#B y|#C z}
    ↓
{?__gsa_g1_1?a|{?__gsa_g1_2?b|c}} and {?__gsa_g1_1?x|{?__gsa_g1_2?y|z}}
#def %__gsa_g1_1% = {x||}      one option of three is non-empty → branch A with p = 1/3
#def %__gsa_g1_2% = {x|}       one of two                       → branch B with p = 1/2 of the rest
```

so A, B and C each end up at 1/3, and both blocks always agree because they read the same
two definitions. A **single** tagged block has nothing to correlate with and is written as
the plain enumeration it is — `{#A a|#B b}` → `{a|b}`, no definitions at all.

**Measured, not assumed.** Eight copies of one tagged block in a single SER article:

| line in the article | SER's own preview |
|---|---|
| eight untagged `{1\|2\|3}` (control) | `1 1 2 3 2 2 1 1` |
| eight `{#P 1\|#Q 2\|#R 3}` (guide's form) | `1 1 1 1 1 1 1 1` |
| eight `{#tagA 1\|2\|3}` (one tag only) | `2 1 1 1 1 1 1 1` |

The control varies, so blocks really are independent by default; the guide's form returning
eight identical digits has probability 3⁻⁷ ≈ 0.05% under independence. The label
correlation is real, and the conversion built on it is right.

### The forms that are refused

Each is lifted out whole and reported in `Unsupported`. Rendering reproduces the source
text exactly.

| form | why it is refused |
|---|---|
| `{#tagA 1\|2\|3}` — a tag on some options only | The third line above. Correlation by the chosen option's INDEX — the behaviour the feature request described — predicts eight identical digits with **probability 1**, and one differed. Seven of eight returned the option the tag sits on, which points back at the guide's per-option rule; what makes the first differ is not known, and one run is not a characterisation. Translating it would mean inventing a rule |
| `{#.de Hallo\|#.com Hello}` — domain tags | Selects on the **target URL's domain**. Not a spin at all: a conditional on host context, which the engine has no way to evaluate |
| a tag repeated inside its own block | The label stops identifying a branch |
| two blocks whose tag sets **overlap without being equal** (one tagged A,B beside one tagged A,C) | They share a tag; whether SER pairs them through it is undocumented. Calling them independent would answer that question silently. **Both** blocks are refused |
| a bare `#`, a tag with no text, a tag carrying a line break | Tag-shaped and unreadable. Falling through to "ordinary spin" would hand the engine a block we admit we do not understand |

A refused block is restored to the author's text **with its macros put back**, so the host
is handed what it wrote rather than the converter's placeholders.

## 6. Macros

### Passed through untouched

These reach SER exactly as written; the engine has no syntax that collides with them.
Each has a verbatim assertion in `tests/gsa_tests.dpr`.

| form | example |
|---|---|
| `%spinfile-…%` | `%spinfile-C:\a.txt%` |
| `%spinfolder-…%` | `%spinfolder-p%` |
| `%columnspinfile-…-N%` | `%columnspinfile-C:\a.txt-2%` |
| `#file=…` | `#file=C:\n.txt` |
| `#spin … #nospin` | `a #spin b #nospin c` |
| `#trans_xx_yy … #notrans` | `#trans_en_de hello #notrans` |

### Lifted into a variable — every **bracketed** macro

| form | example |
|---|---|
| `#name[…]` | `#file[c.txt,1,S]`, `#file_links[names.dat,[2..10],S]`, `#grabbedAll[1,5]`, `#random[…]`, `#gennick[…]`, `#err[…]`, `#openai[…]` |
| `%name[…]%` | `%related_url_link[ignore=a.com\|b.com]%` |

`[` opens a **permutation** in this engine, so leaving them in place is not neutral:

| left alone | renders as |
|---|---|
| `#file[list.txt,1,S]` | `#filelist.txt,1,S` — brackets eaten, macro destroyed before SER sees it |
| `#openai[write a\|b]` | arguments read as options and **shuffled** — still looks like a macro, and is not one |

The macro **name** is read as a GSA identifier — a letter, then letters, digits or
underscore — not from a list, so a macro the guide adds tomorrow is protected too. (A
letters-only rule shipped first and cut `#file_links[…]` short at the underscore.)

### Why a macro cannot be repaired inside the template

`SpRender` **strips** the reserved sentinels U+E000–U+E005 from a template before parsing
it, deliberately, so that author markup cannot forge one. Sentinels legitimately enter a
render only through the host's variables. So the macro has to leave the template — hence the
map, and hence the signature that says so.

The lifted value is stored **neutralized**: structural characters are replaced by those
sentinels, and the engine restores them on the way out.

| character | `{` | `}` | `[` | `]` | `%` | `#` |
|---|---|---|---|---|---|---|
| stored as | U+E000 | U+E001 | U+E002 | U+E003 | U+E004 | U+E005 |

Treat `MacroVars` values as opaque: read them, do not hand-edit them. To recover the
author's text, `SpSafetyRestore` is the public function that undoes it.

## 7. Literals that are ordinary in SER and syntax here

GSA has no permutation form and no comment form, so these are just characters in a SER
template — and this engine reads them. The damage is silent:

| SER template | what this engine would do, unprotected |
|---|---|
| `Read [b]this[/b] now.` | `Read bthis/b now.` — brackets eaten |
| `Price [10\|20] USD.` | `Price 10 20 USD.` — **shuffled** |
| `See http://example.com/#top` | `See http://example.com` — the rest of the **document** swallowed as an unterminated comment |
| a line beginning `#set %x% = 1` | the line disappears, read as a directive |

So `[`, `]`, `/#`, `#/`, and a `#` that opens `#set` / `#def` / `#include` **first on its
line** are lifted the same way a macro is. Identical ones share one variable, so the cost is
four entries however many occurrences there are. BBCode and fragment URLs are everyday
content in an article template — this is not an exotic case.

## 8. Generated names

Every generated name carries a prefix chosen so that it occurs **nowhere in the source
template** (case-insensitively, because the engine folds variable case) and matches **no key
already in `MacroVars`**. A fixed `__gsa_` would collide with a template that itself mentions
`%__gsa_m1%` or defines `#def %__gsa_g1_1%` — both ordinary legal names. Prefix-freedom is
collision-freedom for every generated name at once.

| shape | meaning |
|---|---|
| `<prefix>mN` | a lifted macro |
| `<prefix>lN` | a lifted literal |
| `<prefix>uN` | a refused block (also listed in `Unsupported`) |
| `<prefix>gG_L` | a spintag group's definition, group `G`, level `L` |

Keys are compared **case-sensitively**: `#file[A.txt]` and `#file[a.txt]` are different
macros and get different variables. (They shared one in `v0.4.0` — `TStringList.IndexOf`
folds case by default — which silently replaced one file name with another.)

---

## 9. A complete worked example

Input:

```
Hi, {#T1 friend|#T2 mate}!
We ~{tested it|measured it|shipped it}.
Read [b]the notes[/b] at http://example.com/#top
Source: #file_links[names.dat,2,S] and %spinfile-C:\a.txt%
{#.de Hallo|#.com Hello}, {#T1 see you|#T2 later}.
```

`SpGsaToSpintax` returns:

```
Hi, {?__gsa_g1_1?friend|mate}!
We [tested it|measured it|shipped it].
Read %__gsa_l1%b%__gsa_l2%the notes%__gsa_l1%/b%__gsa_l2% at http://example.com%__gsa_l3%top
Source: %__gsa_m1% and %spinfile-C:\a.txt%
%__gsa_u1%, {?__gsa_g1_1?see you|later}.
#def %__gsa_g1_1% = {x|}
```

`MacroVars` (sentinels shown as `<U+E00x>`):

```
__gsa_l1 = <U+E002>                                                  [
__gsa_l2 = <U+E003>                                                  ]
__gsa_l3 = /<U+E005>                                                 /#
__gsa_m1 = <U+E005>file_links<U+E002>names.dat,2,S<U+E003>           #file_links[names.dat,2,S]
__gsa_u1 = <U+E000><U+E005>.de Hallo|<U+E005>.com Hello<U+E001>      {#.de Hallo|#.com Hello}
```

`Unsupported`:

```
__gsa_u1={#.de Hallo|#.com Hello}
```

Three renders with `PostProcess=False`:

```
Hi, friend!                                    Hi, mate!
We measured it shipped it tested it.           We shipped it measured it tested it.
Read [b]the notes[/b] at http://example.com/#top
Source: #file_links[names.dat,2,S] and %spinfile-C:\a.txt%
{#.de Hallo|#.com Hello}, see you.             {#.de Hallo|#.com Hello}, later.
```

Read across: the tag group stays paired (`friend` … `see you`, `mate` … `later`), the tilde
block emits all three options in a changing order, the BBCode, the fragment URL, the
bracketed macro and the refused domain block come back exactly as written, and
`%spinfile-…%` was never touched at all.

## 10. What is guaranteed, and what is not

**Guaranteed**

- The converter never renders and never draws a random number; the output is a template.
- A construct it does not understand is never rendered as something else — it is lifted, and
  reproduces the source text.
- Every passthrough macro in §6 reaches the output unchanged.
- Nothing here can alter what the engine renders for a non-GSA template.

**Not guaranteed**

- **Selection results.** Which option a spin picks is the engine's RNG, and cross-engine RNG
  parity is an explicit non-goal of this family. A converted template produces the same
  *distribution* SER's rules describe, not the same *sequence* SER would produce.
- **Anything the guide does not document.** Where SER's behaviour is undocumented — the
  partially tagged block, overlapping tag sets — the converter refuses rather than guesses.
  Those cases are yours to resolve through `Unsupported`, with the author's text in hand.

## 11. What survives a round trip, and what is not executed at all

### The engine spins; it does not run SER

Every data-source macro is **preserved, never executed**. `#file[…]`, `#file_links[…]`,
`#file=…`, `%spinfile-…%`, `%spinfolder-…%`, `%columnspinfile-…%`, `#spin…#nospin`,
`#trans_xx_yy…#notrans`, `#grabbedAll`, `#random`, `#gennick`, `#openai`,
`%related_url_link[…]%` — all of them come out of a render as text, for SER to resolve
downstream. Nothing here reads a file, calls an API or picks a nickname.

### Everyday SER text, measured

Convert → render over five seeds, compared byte-for-byte with the input:

| input | result |
|---|---|
| `Save 50% now, 20% later.` | survives |
| `Value %myvar% here.` / `%my_var%` | survives — an unknown `%…%` is left alone |
| `Path C:\dir\file.txt ok.` | survives |
| `Cost { rises.` (a lone brace) | survives |
| `Try ~{a\|b now.` (unclosed tilde form) | survives |
| `x #file[a.txt y` (unclosed macro bracket) | survives |
| `Ping #tag and #set-like text.` | survives |
| `#trans_en_de hi #notrans` | survives |
| `100%% done`, `a ~ b ^ c` | survive |
| `A {placeholder} here.` | → `A placeholder here.` — **spin syntax, not a defect** |

The last row is the ordinary meaning of `{…}` in every engine of this family and in SER
alike: a group with no `|` is a one-option spin, so it emits its single option and the
braces are consumed as the syntax they are. A template that needs literal braces in the
output has to supply them through a host variable, the same as any other reserved
character.

And the forms that would break **without** the lifting of §7 — `[b]bold[/b]`, `[10|20]`, a
`/#` fragment URL, a line opening with `#set`, and a block whose text starts with `?` or
`plural ` (a conditional and a plural here, an ordinary spin in SER) — all survive because
they are lifted, not because they were harmless.

## 12. How this is tested

`tests/gsa_tests.dpr` — 94 assertions, run in CI beside the engine's suites, in both an
optimised and a `-Co -Cr` (overflow and range checked) build, with warnings as errors.

Its rule is **convert-then-render**: assertions are made on what the engine *prints*, never
on the text the converter produced. The first version of the suite checked the transform's
text and stayed green through three defects of exactly the kind this document is about.
