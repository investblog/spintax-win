---
type: decision
status: accepted
tags: [include, render, api, parity, studio]
project: spintax-win
---

# 0004 — The engine grows an `#include` resolver seam

**Date:** 2026-07-25

## Context

This engine recognises `#include` (`MatchIncludeAt`, spec §5.1) and never resolves it.
`SpRender` emits the line verbatim and the host substitutes the text. Until now that read as
a deliberate split — and for the *no-resolver* case it is exactly right: the reference ends
its render with `resolver ? resolveIncludes(text, ctx) : text`, so with no resolver it also
leaves the line alone. The port is at parity for the only case it can express.

What the port lacks is the seam, and the seam is not a convenience. Measured on
`@spintax/core` (`render.ts:91,106`) and confirmed in `spintax-py` (`_render.py:603`), the
family's resolution semantics are **not** what splicing text into the document produces:

| question | family | text-splice by a host |
|---|---|---|
| what is substituted | the child, parsed and rendered **on its own**; its OUTPUT | the child's raw source |
| child scope | inherits the runtime context, **not** the parent's `#set`/`#def` | the child sees the parent's macros |
| unknown target / cycle / depth | `''`, leniently | whatever the host invents |
| `{`, `\|`, `%` in the child's output | already output, never re-parsed | re-parsed by the parent as markup |

A host that splices raw text therefore produces output no other engine in the family
produces — for a document that is *valid everywhere*. `spintax-studio` had written exactly
that design into its ADR 0003 and caught it in review before shipping it.

The argument is the one that put `SpExtractDirectives` here: the alternative is every host
re-deriving this unit's rules, and the first host got three of the four rows wrong.

## Decision

Add the seam. The engine owns the **semantics** (child render, scope, cycles, depth); the
host keeps the **lookup** (files, database, in-memory map) — the same split the reference
makes, and the same shape as the existing `TSpRng` seam.

Additive public API → the next tag after it is a **minor bump**, `v0.3.0`.

### Shape

```pascal
{ Caller-owned, like TSpRng. Resolve returns False for "no such template", which is the
  reference's `null`: an unknown target resolves to the empty string, never to an error. }
TSpIncludeResolver = class
public
  function Resolve(const Ref: string; out Text: string): Boolean; virtual; abstract;
end;
```

`TSpContext` gains two fields, both inert when zeroed, so every existing caller keeps
compiling and behaving identically:

- `IncludeResolver: TSpIncludeResolver` — `nil` means "do not resolve", today's behaviour and
  the reference's no-resolver behaviour;
- `MaxIncludeDepth: Integer` — `0` means the family's `DEFAULT_MAX_DEPTH = 20`.

An abstract class rather than an interface or a function pointer: `TSpRng` is already an
abstract class, interfaces bring ARC differences between FPC and Delphi that this port has
paid for before, and a bare function pointer cannot carry the host's template store.

### Semantics to mirror exactly

1. **Resolution runs at the END of a document's render, before post-process.** The reference's
   order is `renderAst` (which ends with `resolveIncludes`) → `postProcess` → `safetyRestore`
   (`pipeline.ts:39-47`). So the cosmetic pipeline runs **once**, over parent and children
   together, and sentinels a child emitted are restored **once**, at the top. A child is
   rendered by the inner function, never by the public entry point — it must not be
   post-processed on its own.
2. **The child is a document of its own.** Parse it (sentinel strip, comment strip, directive
   extraction — the same path the parent took), build ITS `#set`/`#def`, render it. The
   parent's macros are invisible to it; the runtime context is inherited unchanged.
3. **The same RNG instance threads through.** The child continues the parent's sequence.
4. **Cycles are detected by the ref STRING**, so two aliases of one template are not a cycle
   and unwind until the depth cap. The comparison is **case-sensitive** (`Array.includes`) —
   see the trap below.
5. **Cycle, or stack depth ≥ MaxDepth → `''`.** Leniently; the reference deliberately has no
   `MaxDepthExceededError` (`errors.ts:25`), and `validate` deliberately does not report
   circular includes (`validator.ts:10`) — it is a render-time guard, not a verdict.
6. **The depth cap counts the include stack only.** The reference's `maxDepth` is read in
   exactly one place, `includeStack.length >= ctx.maxDepth`; parse nesting and variable
   expansion have their own limits. (`pipeline.ts`'s docstring calls the constant a
   "#include + parse-nesting guard", which its code does not do — mirror the code.)
7. **A resolver that raises is the host's bug.** The reference wraps it in
   `IncludeResolverError`; this port lets the exception propagate unchanged rather than
   introducing an exception type, and says so — the engine still never throws on its own.
8. **The replacement pass scans the RENDERED text and does not rescan what it inserted.**
   `String.replace` continues after each match, so a child's output is never scanned for
   `#include` by the parent — the child resolved its own. Match extents may cross line
   terminators (spec §5.1), so the pass continues from the match end, not from the next line.

### Step 0, first and separately: case-sensitive target matching

Found while writing this record, and it ships in `v0.2.1`: `KnownIncludes.IndexOf(ref)` and
the `Includes` dedup in `SpExtract` use `TStringList.IndexOf`, which is **case-insensitive**
unless told otherwise, where the reference compares exactly. Measured:

| `#include "X"` with `knownIncludes = ['ok']` | reference | here |
|---|---|---|
| `"ok"` | valid | valid |
| `"OK"` | **invalid** (`include.unknown-target`) | valid |
| `"Ok"` | **invalid** | valid |

Another verdict divergence, and the 86 419-case include differential could not see it: every
target in that corpus matched the slug list in case, so the corpus was incapable of asking the
question — the same trap this repository has recorded twice. `TSpDirective`'s doc comment
even states the wrong behaviour as intentional ("targets are matched case-insensitively, like
KnownIncludes") and must be corrected with it.

Fix by comparing exactly (a helper, not by mutating the caller's `TStringList`, whose
`CaseSensitive` and `Sorted` belong to the host). Patch bump `v0.2.2`, ahead of the resolver
and ahead of Studio pinning an engine.

## Consequences

- `spintax-studio`'s ADR 0003 is rewritten: the engine resolves, Studio supplies a
  `TSpIncludeResolver` over its template set. `SpExtractDirectives` keeps its editor jobs —
  jumping to an include, showing it, validating the closure file by file — and stops being
  the mechanism for expansion.
- Validation is unaffected: it stays on the unexpanded document, and circular includes remain
  a render-time guard rather than a verdict, exactly as in the reference.
- The corpus cannot gate any of this — its schema has no include-resolution field, which is
  §8's standing warning. The gate is a local differential against `@spintax/core` with a
  matching resolver on both sides, plus local tests for the shapes it cannot reach (cycles,
  aliases, the depth cap, a child that emits neutralized markup).
- Include resolution becomes recursive. Depth is capped at 20 by the same rule that caps the
  reference, so the recursion is bounded — unlike the parser's, which had to be iterative.
