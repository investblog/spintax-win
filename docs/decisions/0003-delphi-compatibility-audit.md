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

## Decision (superseded — see the update below)

Fix Finding 1 (verifiable under FPC). **Do not** write the `{$IFDEF UNICODE}` branches for
Finding 2 yet — the fix is easy to guess at and was impossible to prove without a Delphi
compiler, and it sits on the path that guards untrusted input.

---

## UPDATE, same day — Delphi 12 arrived, and the audit was 1 for 3

RAD Studio 12 was installed (Starter edition: the IDE works, `dcc32`/`dcc64` refuse
command-line use). `tests/delphi/sentinel_probe.dpr` was built by hand in the IDE and run.
Full measurements: [tests/delphi/RESULTS.md](../../tests/delphi/RESULTS.md).

**The engine compiles under Delphi 12 with 0 errors.** That was the biggest unknown and it
is now closed.

Scorecard for the static audit above:

| audit claim | measured |
|---|---|
| Finding 1 — `{$MODE}` rejected by Delphi | correct |
| Finding 2 — sentinels break under UTF-16 | **correct, mechanism wrong** |
| Finding 2 note — `Ord(t[i]) >= $80` / set expressions suspect | **refuted** |

**Finding 2's mechanism was wrong in an important way.** The prediction was that
`#$EE#$80#$80` would read as U+00EE U+0080 U+0080. Measured: `U+043E U+0402 U+0080` — the
bytes decoded through the machine's **ANSI codepage** (Windows-1251 here). The corruption
was therefore *locale-dependent*: a different Windows install would produce different
characters again. Predicting "it breaks" was right; predicting *how* was not, and the real
behavior is worse than the guess.

**The set-expression suspicion was a false alarm.** `dcc32` raises `W1050 WideChar reduced
to byte char in set expressions` at 28 sites, and the audit reasoned that a Cyrillic letter
would satisfy an ASCII test (U+0441 has low byte `$41` = `'A'`). Measured:
`Char($0441) in ['A'..'Z']` is **False**. Delphi 12 handles ordinals above 255 safely. The
warning is worth silencing with `CharInSet` for a clean build; it is not a defect. Recorded
so nobody "fixes" 28 call sites for a bug that does not exist.

Had the branches been written blind on the audit's reasoning, they would have encoded the
wrong mechanism and touched 28 innocent sites.

## Decision, revised

Finding 2 is now **fixed and verified**: `Sentinel()` and `FullwidthVerbatim` branch on
`UNICODE`, and the two readers share a new `SentinelAt()` so they cannot drift from the
writer. Before/after on the same compiler: `U+043E U+0402 U+0080` → `U+E000`; a foreign
U+E000 goes from silently unrestored to restored. FPC unchanged at
`PASS=143 FAIL=21 SKIP=4`.

## What is still open

**Corpus parity under Delphi is unmeasured.** `tests/corpus_runner.lpr` uses
`fpjson`/`jsonparser`; running the golden corpus under Delphi means rewriting its JSON
layer against `System.JSON`. Until then the claim is "compiles under Delphi 12, sentinel
encoding verified" — not "at parity under Delphi".

**Nothing guards the fix.** Starter has no command-line compiler, so no gate and no CI can
re-check it; every Delphi verification is a human pressing Shift+F9. Either move to a
licence with `dcc32` (Professional or a trial) and gate it, or accept a dated manual check
and treat every edit to a `{$IFDEF UNICODE}` branch as requiring a re-run.

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
