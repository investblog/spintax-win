---
type: decision
status: active
tags: [scope, postprocess, corpus]
project: spintax-win
---

# 0002 — The cosmetic post-process stage stays minimal, and the gap is gated

**Date:** 2026-07-21

## Context

Measured against the corpus, this port passes 143 of 168 cases, skips 4 by design, and
fails 21. **All 21 are in `render-postprocess.json`**; every other fixture file is at 100%,
including all 40 `validate` cases and all 59 `render-semantics` cases.

The missing behavior is cosmetic: URL / email / domain / decimal / abbreviation shielding,
Spanish sentence openers (`¿` `¡`), and capitalization after sentence boundaries and block
tags through Unicode. The reference implements all of it with Unicode-aware regex; FPC
3.2.2 has no equivalent regex dialect and the port's `string` is a byte string, so this is
the single most expensive part of the engine to reach parity on.

## Decision

Keep the cosmetic stage minimal (ASCII space collapsing, punctuation spacing, first-letter
capitalization). Do **not** treat the 21 as a defect backlog. Do **not** let them rot
silently either: they are enumerated in `tests/known-failures.txt` and gated by
`tests/check-corpus.sh`.

## Why gate a known-failing set at all

`corpus_runner` is a reporter — it prints its counts and exits 0 whatever it finds. CI
wired straight to it would be green with 21 failures, and green-with-21-failures is
indistinguishable from green, so the next real regression lands unnoticed.

The baseline file makes the gate two-directional:

- a **new** failure anywhere fails the build — that is a regression;
- a listed case that starts **passing** also fails the build, until its line is deleted —
  an improvement has to be recorded, not absorbed.

## Consequences

- The semantic contract (parse, render, directives, plurals, conditionals, permutations,
  variables, neutralize, extract, validate) is fully gated and green.
- A consumer needing URL shielding or Spanish openers must either post-process host-side
  or fund the work. That is a visible trade, stated in the README's Scope section.
- Anyone closing one of the 21 must delete its line in the same commit.
