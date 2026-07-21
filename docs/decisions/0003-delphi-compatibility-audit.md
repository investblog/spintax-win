---
type: decision
status: active
tags: [delphi, portability, dpm, audit]
project: spintax-win
---

# 0003 — Delphi compatibility: audited by reading, one blocker fixed, one left open

**Date:** 2026-07-21

## Context

The README claimed the unit is "Delphi-consumable as-is". Nothing had ever tested that:
there is no Delphi on this machine (no Embarcadero registry keys, no `dcc32`), and Delphi
Community Edition cannot be installed unattended — it needs registration and a licence key.
So the claim was audited against the two compilers' documented differences instead of a
compile.

## Finding 1 — `{$mode delphi}` is an FPC-only directive (FIXED)

`src/Spintax.pas:18` opened with a bare `{$mode delphi}{$H+}`. Delphi does not know
`{$MODE}` and reports it as an invalid compiler directive; the portable idiom that every
cross-compiler Pascal codebase uses exists precisely for this.

Changed to `{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}`.

**Verified**, not assumed: `src/Spintax.pas` still compiles when `-Mdelphi` is *removed*
from the command line, which proves the in-source directive is doing the work rather than
the build flag masking it. Full gate re-run: corpus unchanged at `PASS=143 FAIL=21 SKIP=4`.

`tests/corpus_runner.lpr` and `examples/demo.lpr` keep the bare directive on purpose —
they are FPC programs, Delphi never sees them, and the DPM package ships only
`src/Spintax.pas`, `LICENSE` and `README.md`.

## Finding 2 — hard-coded UTF-8 bytes vs. UTF-16 `string` (OPEN, blocking)

The engine encodes two things as raw UTF-8 byte sequences in `Char` literals:

| what | where | literal |
|---|---|---|
| sentinels U+E000–E005 | `Sentinel()` :268, `SpSafetyRestore` :297, `SpStripSentinels` :319 | `#$EE#$80 + Chr($80+i)` |
| fullwidth braces U+FF5B / U+FF5D | `FullwidthVerbatim` :901–902 | `#$EF#$BD#$9B`, `#$EF#$BD#$9D` |

Under FPC `{$mode delphi}` + `{$H+}`, `string` is `AnsiString` and `Char` is one byte, so
those are exactly the UTF-8 encodings intended. Under Delphi 2009+, `string` is
`UnicodeString` and `Char` is `WideChar`: the same literal becomes **three** UTF-16 code
units (U+00EE, U+0080, U+0080) instead of the single code point U+E000.

Consequences under Delphi:

1. **Corpus divergence.** The reference emits one U+E000; this would emit three unrelated
   characters. The 8 `neutralize` cases and the fullwidth-brace leniency cases would fail.
2. **The mandatory safety restore silently fails.** `SpSafetyRestore` looks for the byte
   triple. A value neutralized by a *host* or another engine carries a genuine U+E000,
   which would no longer match — so structural characters from untrusted (T2) input would
   pass through unshielded. That is a trust-model violation, not a cosmetic bug.

The engine would still be *self*-consistent (its own neutralize/restore round-trips),
which is exactly why this would not announce itself.

Not blocking-but-worth-review: `:961` uses `Ord(t[i]) >= $80` as "non-ASCII letter". The
intent survives the byte→code-unit change, but the meaning shifts.

The purely structural scan is **safe** either way — it branches only on ASCII characters,
whose values are identical in UTF-8 bytes and UTF-16 code units, and non-ASCII never
collides with them. The unit header already argues this correctly; it just does not cover
the two byte-literal sites above.

## Decision

Fix Finding 1 (verifiable under FPC). **Do not** write the `{$IFDEF UNICODE}` branches for
Finding 2 yet.

The fix is easy to guess at and impossible to prove here: it changes what the engine emits,
on a compiler that cannot run a single fixture on this machine. Shipping an untested
conditional branch through the one path that guards untrusted input would trade a *known*
limitation for an *unknown* one, and `proof-loop` does not accept "it looks right" as
evidence. It stays documented and open.

## What actually unblocks it

A Delphi compiler. GitHub Actions has no free Delphi runner, so CI cannot cover this.
Either install Delphi CE locally and run `tests/corpus_runner` built by `dcc32`, or accept
FPC-only support and drop the Delphi claim from the package metadata.

## DPM: the spec is closer to correct than expected

Checked against the DPM repository rather than memory:

- The client's reader (`Source/Core/Spec/DPM.Core.Spec.Reader.pas`) parses **YAML only**
  via `VSoft.YAML` — there is no JSON code path — and accepts `.dspec` / `.dspec.yaml`.
  Our file is JSON with a `.dspec` extension. That still loads: `VSoft.YAML` advertises
  "full JSON input support", YAML 1.2 being a superset of JSON.
- `docs/dspec-format.md`, which the repo calls the definitive reference, documents exactly
  the shape we use: `compiler: "12.0"` singular, and `platforms` as a comma-separated
  string. **The JSON schema checked into that same repo disagrees** (it wants `compilers`
  as an array and `delphi12.0` enum values). Docs and reader win over the schema; our file
  was not changed.
- One real defect: the `$schema` URL 404'd — `schemas/dspec.schema.json` does not exist.
  Corrected to `Schema/dspec-yaml-schema.json`, verified HTTP 200.

Still unverified: whether the package actually *builds* under DPM. That needs DPM, which
needs Delphi.
