---
type: decision
status: accepted
tags: [gsa, ser, dialect, converter, interop]
project: spintax-win
---

# 0005 — GSA SER templates are converted, not absorbed

**Date:** 2026-08-06 — implemented the same day, `src/Spintax.Gsa.pas`.

## Context

GSA Search Engine Ranker is a Delphi tool with its own spin dialect and a large installed
base of templates. Its author was offered this engine and replied that it was missing two
constructs of his syntax, and that a template of his would therefore not run here.

The obvious response is to add the two constructs. That is the wrong shape. This engine's
whole claim is that it renders the same thing as the TypeScript, PHP and Python engines,
and the thing that makes that true is the shared corpus. Syntax added here and nowhere else
is a fork of the contract with the family's name still on it.

Reading GSA's own [macro guide](https://docu.gsa-online.de/search_engine_ranker/macro_guide)
rather than the feature request changed the problem substantially:

| construct | as described in the request | as the guide documents it |
|---|---|---|
| `~{a\|b\|c}` | options emitted **in order** | *"all variations are used but in a random order"* |
| `{#TAG …}` | tag on the **block**, correlate by **index** | tag on each **option**, correlate by **label** |

So one of the two "missing" constructs was not missing at all: *all elements, shuffled* is
this family's permutation, and `[a|b|c]` reproduces the guide's own worked example, joining
with a single space as the guide shows. And the other needs no new syntax either, because
`#def` resolves once per render and holds — which is exactly a choice made once and reused.

Measuring the engine against the guide also turned up a defect that the request did not
mention and that we had, in writing, claimed the opposite of. `#file[list.txt,1,S]` is a SER
data-source macro, but `[` opens a **permutation** here, so the engine renders it as
`#filelist.txt,1,S`: the brackets are eaten and the macro is destroyed before SER sees it.
Every `%…%` macro (`%spinfile-f%`, `%spinfolder-p%`, `%columnspinfile-f-2%`) does pass
through untouched, as does `#file=f` and `#spin…#nospin` — the bracketed form is the one
that breaks, and it is the one we assured him was safe.

## Decision

A GSA template is **converted into this engine's syntax** by an optional unit that the
engine does not know about. `Spintax.Gsa` is not built into `Spintax`, is not gated by the
corpus, and adds nothing to the engine's public surface; it has its own suite,
`tests/gsa_tests.dpr`, run by CI beside the others and held to the same two bars — warnings
as errors, and a second build with `-Co -Cr`.

    function SpGsaToSpintax(const Src: string; MacroVars: TStrMap;
                            Unsupported: TStrings): string;

- `~{a|b|c}` → `[a|b|c]`. Textual, exact.
- Spintags in the guide's form only — every option tagged, correlated by label. Each group
  becomes one `#def` chain: n−1 definitions, the i-th non-empty with probability 1/(n−i+1),
  which is uniform over the n branches. A group of a single block needs no correlation and
  is written as the plain enumeration it is.
- `#name[...]` and `%name[...]%` → a `%…mN%` reference, macro text neutralized into
  `MacroVars`.
- Anything it cannot express → lifted out too, and reported in `Unsupported`.

## The rule the second review forced

The first version said unsupported blocks were "left exactly as written". They were — in
the *template*. Then `SpRender` read `{#.de Hallo|#.com Hello}` as an ordinary enumeration
and printed `#.de Hallo`: a random branch, with the tag still attached. The comment
promising not to invent a choice sat directly above code whose output invented one.

So the rule is now explicit: **a conversion may never leave the engine free to render a GSA
construct as something else.** Not-understood is not left in place; it is lifted OUT into a
variable, which makes the default render reproduce the source text exactly and gives a host
somewhere to put its own answer. What is lifted:

- `{#.de Hallo|#.com Hello}` — selects on the **target URL's domain**. Not a spin at all,
  but a conditional on host context.
- a block where only SOME options carry a tag, or whose tag repeats across its own options.
- blocks whose tag sets overlap without being equal (one tagged A and B beside one tagged
  A and C). They share a tag; whether SER pairs them through it is undocumented, so calling
  them independent would answer that question silently.

A lifted block is restored to the author's own text first, macros included, so the host is
handed what it wrote rather than this unit's placeholders.

## Why a macro cannot be fixed in the template text

Neutralizing the brackets where they stand does not work: `SpRender` **strips** reserved
sentinels from a template before parsing it, deliberately, so that author markup cannot
forge one. Sentinels legitimately enter a render only through the host's variables. So the
macro has to leave the template, and the signature has to say so.

A host that ignores `MacroVars` gets `%__gsa_m1%` in its output — visibly wrong, rather
than a macro quietly missing its brackets. That was the deciding argument over anything
that fails silently.

The macro NAME is read as a GSA identifier — a letter, then letters, digits or underscore —
not from a list. A letters-only rule shipped in the first version and cut `#file_links[...]`
short at the underscore, which left a documented macro unprotected; `#grabbedAll`,
`#gennick`, `#random`, `#err`, `#openai` and `%related_url_link[ignore=a.com|b.com]%` are
all in the same family. The last two matter most: a `|` inside the brackets makes the engine
read the macro's arguments as options and **shuffle** them, which is worse than truncation
because the output still looks like a macro.

## Namespace

Generated names carry a prefix chosen so it occurs nowhere in the source template,
case-insensitively, and among no key already in `MacroVars`. A fixed `__gsa_` collides with
a template that mentions `%__gsa_m1%` or defines `#def %__gsa_g1_1%` — both ordinary legal
names — and the engine folds variable case, so the check folds it too. Prefix-freedom is
collision-freedom for every generated name at once.

## The form from the request, measured in SER and dropped

The request described a second shape: the tag naming the whole BLOCK, with the chosen
option's INDEX reused by every later block carrying that tag —
`{#tag1 a|b} … {#tag1 c|d}` giving `a…c` or `b…d`. It is textually distinguishable from the
guide's form (only the first option tagged, versus all of them), so an earlier revision of
this unit supported both and declared neither wrong.

It was then run in SER's own Article Manager. Eight copies of the same one-tag,
three-option block in one article:

| line | result |
|---|---|
| eight untagged `{1\|2\|3}` (control) | `1 1 2 3 2 2 1 1` |
| eight `{#P 1\|#Q 2\|#R 3}` (guide's form) | `1 1 1 1 1 1 1 1` |
| eight `{#tagA 1\|2\|3}` (request's form) | `2 1 1 1 1 1 1 1` |

The control varies, so the preview really spins and blocks are independent by default. The
guide's form returns eight identical digits, which under independence has probability
3⁻⁷ ≈ 0.05% — the label correlation is real, and the conversion built on it is right.

The third line refutes the request's description: correlation by index predicts eight
identical digits with **certainty**, and one differs. So the conversion was removed. Seven
of the eight returned `1`, the option the tag actually sits on, which points back at the
guide's per-option rule applied to a block where one option is tagged and the rest are not
— but what makes the first block differ is not known, and one run is not a characterisation.
Such blocks are refused and handed to the host rather than translated into a rule we
invented.

Worth saying plainly: this is the SER author's own description of his own syntax, and his
engine does not do it. The measurement is the thing to send him, not an opinion.

## v0.4.1 — two defects a second review found in v0.4.0

**A lifted construct was keyed case-insensitively.** `TStringList.IndexOf` folds case, and
the lifter keys on the author's own text, so `#file[A.txt,1,S]` and `#file[a.txt,1,S]`
shared one variable and the second rendered as the first — a file name silently replaced by
another, in a published tag. This is the same defect the family fixed in `v0.2.2`, where
`IndexOf` folded an include target; it is worth treating every `TStringList` lookup over
user text as case-folded until proved otherwise.

**Partly overlapping tag sets were silently called independent**, which is a ruling on an
undocumented case rather than a translation of a documented one. They are refused now.

## Consequences

- An existing SER template runs on this engine unchanged, which is the adoption argument
  the feature request was really about — and it holds whether or not SER ever adopts the
  engine.
- The engine's contract is untouched: corpus `PASS=200 FAIL=0 SKIP=4` and the 411 local
  assertions are unaffected by anything in this ADR, because nothing in it is in the engine.
- The form the feature request described is **not** supported, and that is a measurement
  rather than a judgement — see below.
- The tag encoding is verbose, and that is a symptom: `{?VAR?a|b}` tests only whether a
  variable is set. A value-equality conditional would reduce a group to one definition and
  one test per block. It is in the backlog as a family question, not a local edit.
- Emitted definitions are **appended**, because a directive leaves its line break behind, so
  the blank lines land after the document instead of shifting it down. `PostProcess=True`
  removes them.
- Nesting is handled recursively and `FindClose` rescans, so cost is quadratic in depth:
  measured 32 ms at depth 1000 and 1016 ms at 5000, surviving depth 24000 without
  exhausting the stack. No hand-written SER template is anywhere near that, so it is
  recorded rather than fixed.
