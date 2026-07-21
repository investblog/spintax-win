---
type: note
status: active
tags: [delphi, evidence, portability]
project: spintax-win
---

# Delphi probe — measured results

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

## What is still NOT proven under Delphi

The probe covers the sentinel contract, one round-trip and a smoke render. **The
golden corpus has never run under Delphi** — `tests/corpus_runner.lpr` depends on
`fpjson`/`jsonparser`, which Delphi does not have, so porting it means rewriting
the JSON layer against `System.JSON`.

So the supportable claim today is: *the engine compiles under Delphi 12 with 0
errors, and its sentinel encoding is correct there*. Not: *it is at parity under
Delphi*. Nothing has measured the other 1987 lines on that compiler.

