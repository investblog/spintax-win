---
type: note
status: active
tags: [delphi, evidence, portability]
project: spintax-win
---

# Delphi probe — measured results

> **Current as of 2026-07-22 — see run 7 at the bottom.** Earlier runs measured older
> trees and are kept for the history of how the divergences were found.

Delphi 12 Athens (CompilerVersion 36), Win32/Debug, `dcc32` via the IDE
(Starter edition has no command-line compiler). Engine unit compiled with
**0 errors**.

## Run 1 — before the encoding fix

```
SizeOf(Char)      = 2
UNICODE defined   = yes  -> string is UnicodeString
compiler          = Delphi, CompilerVersion 36

--- Sentinel(0) ---
SpNeutralize('{') length = 3
  code units: U+043E U+0402 U+0080
  VERDICT: THREE code units, not the reference's single U+E000.

--- set-expression truncation (WideChar -> byte) ---
  Char($0441) in ['A'..'Z'] = False
  not reproduced - the compiler did not truncate here

--- engine round-trip ---
  neutralize -> restore = {a|b}
  OK: the engine is self-consistent

--- foreign (host-neutralized) sentinel ---
  input     : U+E000 U+0061
  restored  : ?a
  FAILS: a genuine U+E000 is NOT restored

--- smoke render ---
  {a|b|c}    -> a
  cyrillic   -> товар        (correct; the console cannot render it)

exit code = 3
```

### What the numbers mean

**The sentinel corruption is locale-dependent.** The predicted result was
`U+00EE U+0080 U+0080` — a literal reading of `#$EE#$80` as two code points. The
actual result is `U+043E U+0402`, which is byte `$EE` and byte `$80` decoded
through **Windows-1251**, this machine's ANSI codepage. So the compiler treated
the literal as a byte string and converted it using the system codepage: on a
machine with a different ANSI codepage the sentinels would be *different
characters again*. The corruption is not even reproducible across Windows
installs.

**The trust-model failure is confirmed.** `SpSafetyRestore` cannot see a genuine
U+E000 produced by a host or a sibling engine, so structural characters from
untrusted (T2) input reach the parser unshielded — while the engine's own
neutralize/restore round-trip keeps working, which is exactly why nothing would
announce the problem.

**The set-expression warning is NOT a correctness defect.** `W1050 WideChar
reduced to byte char` fires on 28 `ch in [...]` sites in the engine, and the
hypothesis was that a Cyrillic letter would satisfy an ASCII test (U+0441 has low
byte `$41` = `'A'`). Measured: `False`. Delphi 12 evaluates ordinals above 255
safely. The warning is worth silencing with `CharInSet` for a clean build, but it
does not change behavior. **This one was a false alarm from the static audit** —
recorded so it is not "fixed" again by the next reader.

The static audit in [decisions/0003](../../docs/decisions/0003-delphi-compatibility-audit.md)
predicted finding 1 correctly, got its details wrong, and raised finding 3 as a
suspicion that measurement refuted.

## Run 2 — after the encoding fix

Same compiler, same probe, full rebuild (Shift+F9 — an incremental Ctrl+F9 is a
no-op if the exe is missing and reports a misleading `Total Lines 0`).
Build: 1987 lines, 0 errors, 31 warnings (the `W1050` set-expression noise), 5 hints.

```
--- Sentinel(0) ---
SpNeutralize('{') length = 1
  code units: U+E000
  VERDICT: single code point U+E000 - matches the reference

--- foreign (host-neutralized) sentinel ---
  input     : U+E000 U+0061
  restored  : {a
  OK: a genuine U+E000 from outside is restored to '{'

--- engine round-trip ---
  neutralize -> restore = {a|b}   OK

exit code = 0
```

| | before | after |
|---|---|---|
| `SpNeutralize('{')` | `U+043E U+0402 U+0080` | `U+E000` |
| foreign `U+E000` restored | no — silently | yes |
| exit | 3 | 0 |

FPC is unchanged across the same fix: `PASS=143 FAIL=21 SKIP=4`.

## Run 3 — the full golden corpus under Delphi

After porting the runner to `SpxJson` (one source, both compilers). Built in the IDE,
Win32/Debug, 2277 lines, **0 errors**, 30 warnings (the `W1050` noise), 9 hints.

| | FPC 3.2.2 | Delphi 13 |
|---|---|---|
| PASS | 143 | **142** |
| FAIL | 21 | **22** |
| SKIP | 4 | 4 |

The 21 shared failures are the known post-process remainder. The 22nd is new, and it is
in `render-semantics.json` — a file that is 59/59 under FPC.

### The divergence: `def/dependency-through-a-set-alias`

```
want = \n\n1 item      (U+000A U+000A U+0031 U+0020 U+0069 U+0074 U+0065 U+006D)
got  = \n\n1           (U+000A U+000A U+0031 U+0020)
```

The plural block vanished while the count rendered.

**Cause — and it is not a Delphi bug.** `SpRender` rolls `#def` values by iterating a
`TDictionary` (`Spintax.pas:1163`), whose enumeration order is implementation-defined.
FPC's hash layout happens to reach `%a%` before `%b%`; Delphi's does not. The code says so
itself one line above: *"Full dependency ordering is simplified; single-level cases pass."*

The fixture is built precisely to catch this. `%b%` does not mention `%a%` anywhere in its
own text — it reaches it through the `#set` macro `%s%`, which is expanded at reference
time — and the declaration order is deliberately reversed. When `%b%` is rolled first it
freezes with `%a%` unexpanded, the plural count is no longer numeric, and the block
disappears. The fixture's own note describes exactly this failure.

**So the bug is present on both compilers; FPC merely gets lucky.** A green corpus under
FPC is not evidence of correct `#def` ordering — a different key set, or a future FPC hash
change, would flip it. Ordering must not depend on hash-map enumeration.

This is a REQUIRED-parity surface (directive semantics), not an allowed divergence.

## Run 4 — parity reached (2026-07-21)

After rolling `#def` values in dependency order. Delphi 13, Win32/Debug, 2407 lines,
0 errors.

| | FPC 3.2.2 | Delphi 13 |
|---|---|---|
| PASS | 143 | **143** |
| FAIL | 21 | **21** |
| SKIP | 4 | **4** |

Not just equal totals — the failing sets were compared **case by case** against
`tests/known-failures.txt` and are identical. Both compilers fail exactly the 21 known
post-process cases and nothing else.

**This is the first claim about Delphi in this repository backed by all 168 fixtures
rather than by reading.**

### What each compiler has actually measured

| | Delphi 12 Athens | Delphi 13 Florence |
|---|---|---|
| engine compiles | yes, 0 errors | yes, 0 errors |
| sentinel probe | yes (runs 1–2) | — |
| full golden corpus | no | **yes (run 4)** |

Both are `{$IFDEF UNICODE}`-identical for this unit, so the package declares the 12.0–13.0
range; only 13 has run the corpus.


## Run 5 — three environments agree (CI, 2026-07-21)

CI green on all jobs: `corpus (ubuntu-latest)`, `corpus (windows-latest)`, `shellcheck`.

| environment | result |
|---|---|
| FPC 3.2.2, i386-win32 (local) | 143 / 21 / 4 |
| FPC 3.2.2, x86_64-linux (CI) | 143 / 21 / 4 |
| FPC 3.2.2, i386-win32 (CI) | 143 / 21 / 4 |
| Delphi 13 Florence, Win32 (manual) | 143 / 21 / 4 |

### The Linux-only failure, and two wrong diagnoses before the right one

`postprocess/abbrev-whitelist-ru` passed everywhere except Linux, where
`"Текст соц. сети тут"` rendered with every space deleted.

**Diagnosis 1 (wrong):** the byte `$D1` matching `[',',';',':','!','?','.']` — the
W1050 class. ASCII guards were added; the failure did not change, which is what
disproved it. The guards stayed, but they fixed nothing.

**Diagnosis 2 (right, and only after dumping bytes):**

```
want<19:3F 3F 3F 3F 3F 20 3F 3F 3F 2E 20 ...>
tmpl<19:3F 3F 3F 3F 3F 20 3F 3F 3F 2E 20 ...>
```

Those `3F` are real bytes. A 19-character, ~34-byte string reached the engine as 19 bytes
with every Cyrillic character replaced by a literal `'?'`. `fpjson` returns `UTF8String`;
assigning it to `string` converts to `DefaultSystemCodePage`, which comes from the locale.
The runner has `LANG=C` → ASCII → lossy. Windows has a Cyrillic ANSI codepage, so the same
conversion round-tripped and the case passed there.

The vanished spaces were the *second* link: once a character is a literal `'?'`, it
genuinely belongs to the punctuation set and post-process correctly removed the space.

Fix: the host declares `DefaultSystemCodePage := CP_UTF8`. The engine's contract is raw
UTF-8 bytes in `string`, and a library cannot set that for its callers.

**Correction to the record:** an intermediate commit message claimed this vindicated the
W1050 suspicion. It did not. The Delphi measurement stands — that construct is not
truncating on Delphi 13 — and this bug had a different cause entirely.

**Method note:** two diagnoses failed while reading glyphs, because every terminal and CI
log renders non-ASCII as `?` — exactly the information an encoding bug lives in. The byte
dump (`SPINTAX_HEX=1`) settled it immediately. For a port about encoding, the harness has
to show bytes; that should have been built before the guessing started.

## Run 6 — parity re-established, and the manual build earned its keep (2026-07-22)

Delphi 13 Florence, Win32/Debug, both binaries built by hand.

| | FPC 3.2.2 | Delphi 13 |
|---|---|---|
| `corpus_runner` | 143 / 21 / 4 | **143 / 21 / 4**, failing set identical case for case |
| `local_tests` | 31 / 0 | **31 / 0** |
| build diagnostics | 0 from our sources | **0 errors, 0 warnings, 0 hints** |

`W1050` is gone: 30 → 0, after replacing every `c in [...]` with `CharInSet`.

### What only the Delphi build could find: EIntOverflow in the PRNG

The first run of `local_tests` under Delphi failed on the nil-RNG case with
`EIntOverflow`. mulberry32 is 32-bit wraparound arithmetic by definition, and Delphi's
Debug configuration enables overflow and range checks, so every mix step raised.

It hid behind two compounding facts: **the corpus skips every `kind:rng` case by design**,
so the generator was never executed by the suite at all, and it only became reachable at
render time when a nil `Ctx.Rng` started defaulting to it. The fix for one crash had
introduced another, on the one compiler that could not run the tests.

**The durable outcome is not the fix but the capability.** `fpc -Co -Cr` reproduces
Delphi's Debug checks, verified by regression: removing the `$IFOPT` suppression makes the
checked FPC build report the *same two failures* Delphi did, while the ordinary build stays
green. `build.sh` now produces both binaries and the gate and CI run both — so this
bug class no longer needs a human with an IDE.

### A decision that paid off

Delphi's editor reports `local_tests.dpr` as **ANSI**. Had the Slavic plural cases stayed
in this file, their Cyrillic literals would have been read in the machine's ANSI codepage
and the test would have compared the wrong bytes. Keeping the source verifiably ASCII-only
— and leaving the Slavic buckets to the 37 corpus cases that already gate them — was what
made this file safe to compile on both.

## Run 7 — full post-process, both compilers agree (2026-07-22)

The cosmetic stage went from minimal to a complete port of the reference's 12-step
pipeline. Delphi 13 Florence, Win32/Debug, both binaries rebuilt by hand.

| | FPC 3.2.2 | Delphi 13 |
|---|---|---|
| `corpus_runner` | **164 / 0 / 4** | **164 / 0 / 4** |
| `local_tests` | 292 / 0 | 272 / 0 |
| build | clean | 0 errors, 0 warnings |

`tests/known-failures.txt` is empty: the whole golden corpus passes on both.

The local counts differ by exactly 20 **by design**: ten decoder-contract assertions are
`{$IFNDEF UNICODE}`, because malformed UTF-8 has no meaning under UTF-16.

### What the rebuild caught, again

The first attempt failed to compile where FPC was clean:

- `E2029` — Delphi requires an `initialization` section before a `finalization` one; FPC
  accepts `finalization` alone. The finalization had been added the commit before, on a
  reviewer's note about a leaked global, and verified under FPC only.
- `W1024` — the surrogate-pair arithmetic mixed signed `Ord()` with an unsigned `LongWord`
  result. Harmless on that path, but a warning in a file whose warnings are meant to be
  fatal teaches people to ignore them.

The pipeline itself needed **no** changes for UTF-16, which was the open risk: the new
scanners are full of index arithmetic and code units are not bytes there. The Unicode
foundation from Phase 0 is why -- everything that reasons about characters goes through
`SpCodePointAt`, so the arithmetic never assumed a width.

## What is still NOT guarded

Parity is **measured**, not **defended**. Neither licence on this machine grants the
command-line compiler — Starter never had it, and per Embarcadero's own support article
*"trial licenses don't include the final command line compilers"* — so no hook and no CI
can re-run this. Every Delphi check is a human pressing Shift+F9, and the Architect trial
expires ~2026-08-21.

Practical consequence: **any edit to a `{$IFDEF UNICODE}` branch, to `#def` ordering, or to
anything touching string width is unverified until someone rebuilds this by hand.** A green
FPC corpus does not cover it — that is precisely how the `#def` ordering bug survived.

