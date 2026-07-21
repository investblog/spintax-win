---
type: decision
status: active
tags: [corpus, ci, parity]
project: spintax-win
---

# 0001 — The golden corpus is checked out, never vendored

**Date:** 2026-07-21

## Context

The port's whole claim is parity with `@spintax/core`, `spintax/core` and `spintax-core`.
That claim rests on one artifact: the shared JSON fixture corpus in
`spintax-js/packages/conformance/fixtures/`. The obvious convenience is to copy the
fixtures into this repo so the tests run with no setup.

## Decision

Do not vendor them. The runner takes a fixtures path; locally it comes from
`SPINTAX_FIXTURES`, in CI from an `actions/checkout` of `investblog/spintax-js`.

## Why

A vendored copy drifts, and a drifting contract is not a contract — the suite would keep
passing against a snapshot of what parity used to mean, which is worse than having no
suite, because it still reports green. The sibling ports already run the checkout pattern
in production.

## Cost, accepted

A fresh clone cannot run the tests without pointing at a corpus. That is made explicit
rather than papered over: `tests/check-corpus.sh` **fails** when `SPINTAX_FIXTURES` is
unset or the directory holds fewer than 7 fixture files, instead of quietly succeeding
over zero cases.

## Alternatives rejected

- **Vendor + a sync script.** Same drift, plus a script nobody runs.
- **Git submodule.** Pins a revision, which reintroduces drift with extra ceremony, and
  submodules are a known footgun on Windows checkouts.
