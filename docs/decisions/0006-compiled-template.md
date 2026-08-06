---
type: decision
status: accepted
tags: [api, render, performance, studio]
project: spintax-win
---

# 0006 — A template can be parsed once and rendered many times

**Date:** 2026-08-06 — implemented the same day.

## Context

`SpRender` parses on every call. That was never questioned, because nothing had measured
where a render's time goes. Phase timing did:

| template | parse | render | free | other |
|---|---|---|---|---|
| article 3.7 KB, `PostProcess=False` | 51.7% | 3.0% | 32.4% | 12.9% |
| article 3.7 KB, `PostProcess=True` | 34.0% | 2.5% | 20.1% | 43.4% |
| 64 KB dense, `PostProcess=False` | 56.7% | 3.5% | 35.8% | 4.1% |

**Rendering is 3%.** Everything else is building the node tree and destroying it — 84% of
an article render, 93% of a construct-dense one. `TNode` carries the fields of all six node
kinds, so every literal costs a full allocate-zero-finalize, and `{a|b}` costs six objects
plus a `TStringList` from the option split.

For a host that renders one template thousands of times — a content tool spinning the same
message, an editor repainting a preview — that whole 84% is paid again on every call.

Two ways to attack it. Optimising the parser is a poor trade: dropping the option split's
`TStringList` buys maybe 10–14% of parse, and collapsing literal-only options into the AST
is a rewrite of the representation the corpus gates. Not parsing twice removes all of it.

## Decision

    TSpTemplate = class ... end;          { opaque }
    function SpCompile(const Template: string): TSpTemplate;
    function SpRenderCompiled(Tmpl: TSpTemplate; const Ctx: TSpContext): string;

`SpRender` is unchanged and now calls the same two halves in sequence, so the one-shot path
and the compiled path cannot drift apart. `#include` children still compile per render:
their source comes from the resolver at render time, so there is nothing to cache them by.

**What is cached:** the sentinel strip, the comment strip, the directive extraction, the
body's node tree, and the node tree of each `#def` value.

**What is not, and cannot be:** the `#def` roll. A definition resolves once per *render*,
and its rolling ORDER depends on the host's variables — a runtime variable of the same name
outranks a definition and changes which aliases the dependency graph can see. So the trees
are reused and the ordering is recomputed, which costs O(definitions), not O(document).

**The state is opaque.** `TSpTemplate` holds a single `TObject`; the node tree stays in the
implementation. Exposing it would make an internal representation part of the contract, and
the whole point of the family's contract is that the representation is each engine's own.

## Measured

Per render, same machine, FPC 3.2.2 / i386 / `-O3`:

| | `SpRender` | compiled | |
|---|---|---|---|
| 3.7 KB article, 160 blocks, PP off | 0.98 ms | 0.04 ms | 25× |
| 3.7 KB article, PP on | 1.53 ms | 0.68 ms | 2.3× |
| 64 KB sentence-long options, PP off | 5.27 ms | 0.44 ms | 12× |
| 64 KB sentence-long options, PP on | 17.8 ms | 12.6 ms | 1.4× |
| 64 KB, a construct every five bytes, PP off | 52.3 ms | 1.90 ms | 27× |

The projection before building this was ~6×, from parse+free being 84%. It came out higher
because the sentinel strip, comment strip and directive extraction — counted as "other" —
are cached too. With the cosmetic stage on the gain is far smaller, because that stage runs
per render and now dominates what is left; that is the honest number to quote to anyone who
needs the typography.

## Why the equivalence is asserted rather than argued

The node tree is now REUSED. A render that mutated it would poison every later render, and
reading the walk to conclude it does not is exactly the kind of argument this project has
been wrong about before.

A 1500-template differential renders each template through both paths under the same seed,
with the cosmetic stage on and off, then renders the compiled one a second time with the
same seed: **0 differences** and **0 changes from reuse**. Two control mutations of the new
code — freezing the `#def` roll after the first render, and letting the walk drop a node —
produce 385/109 and 4446/4225. Eight local assertions pin the shapes with state: the seed
equivalence, reuse, `#def` re-rolling, a runtime variable outranking a definition and the
template still serving the next caller, `#set` still being a macro, and the comment strip
happening once.

## Consequences

- Additive. Existing hosts are untouched; `SpRender` has the same signature and behaviour.
- The caller owns the `TSpTemplate` and frees it. There is no cache, no eviction and no
  thread-safety claim — the engine has no other global state and none is added here.
- `spintax-studio` can compile a template once per editor buffer instead of per keystroke.
- The remaining per-construct cost is untouched and still undiagnosed as to its exact
  split; it simply stops being paid on every render.
