# spintax-win — AGENTS.md

Object Pascal (Delphi-mode) port of the spintax engine, held to the same shared golden
corpus as the TypeScript, PHP and Python engines. Zero dependencies, MIT, FPC 3.2.2+ in
`{$mode delphi}`, Delphi-consumable as-is.

`CLAUDE.md` is a symlink to this file — one charter, every agent.

## Pointer (where to look, in priority order)

- Rules: first `./.agents/rules/`, then the library `~/.agents/rules/`.
- Skills/agents: first `./.agents/`, then the library.
- Links and MCP configs: first the local `./.agents/map.yaml` + `./.agents/mcp-configs.yaml`;
  `~/.agents/...` — only to deploy a new rule. The build snapshot — in
  `./.agents/generated/.agents.lock.yaml`.
- Adaptation registry: `./.agents/REGISTRY.md` — WHY something was added/changed (the WHAT
  graph lives in `map.yaml`, do not duplicate it).
- **[CRITICAL] Plans, docs, and work-artifacts live ONLY in this project** —
  `./.agents/plans/{active,done}`, `./docs/`, the project tree. **NEVER write them to
  `~/.claude/`, `~/.codex/`, `~/.config/opencode/`, or any home/global agent folder.**
  Scratch/temp → the session scratchpad or a gitignored project dir.
- On conflict the project wins (more specific overrides more general).

## Project context

- **Family.** `W:\projects\spintax-js` — `@spintax/core`, TS/MIT, the reference engine
  **and the home of the golden corpus**. `W:\projects\spintax-php` — `spintax/core`,
  Packagist/MIT. `W:\projects\spintax-py` — `spintax-core`, PyPI/MIT. `W:\projects\spintax`
  — the WordPress plugin, PHP/**GPL**, the origin engine. Syntax reference: https://spintax.net
- **Independent implementation, NOT a transcription.** The PHP plugin is **GPL — do not
  transcribe it**; that would pull GPL into an MIT package. Reimplement from the behavior
  contract plus the corpus. `@spintax/core` (TS) is our own MIT code and IS a legitimate
  reference — mirror its *behavior*, not its TypeScript.
- **Corpus-first.** The acceptance suite is the shared JSON corpus at
  `spintax-js/packages/conformance/fixtures/`, reached through `SPINTAX_FIXTURES` locally
  and an `actions/checkout` of `investblog/spintax-js` in CI. **Never vendored** — a copy
  would drift, and a drifting contract is not a contract. A behavior change is justified
  against the corpus, not vibes.
- **Parity REQUIRED** on the deterministic surface: accepted syntax, validation verdicts,
  plural buckets, `{?…}` truthiness, directive semantics (`#set` is a **macro** — re-rolled
  at every reference; `#def` resolves **once per render** and holds), and the post-process
  pipeline. **Allowed to diverge:** RNG selection results, internal architecture, diagnostic
  message strings, performance. Cross-engine RNG-sequence parity is an explicit **non-goal**.
- **Current state:** the deterministic semantic gate and the static validator pass;
  `render-postprocess` is 17/39 because the cosmetic stage is deliberately minimal. See
  `docs/spec-pascal-port.md` for the full contract and `docs/TODO.md` for the remainder.

## Pascal-specific traps (this port's terrain)

- **`{$mode delphi}` is the contract.** Anything that only compiles under `{$mode objfpc}`,
  or needs FPC-only RTL, is a portability break even when the corpus stays green.
- **Warnings are fatal.** Build with `-Sew`. FPC compiles an uninitialised function result
  or a shadowed variable with only a warning, and those are exactly the defects a port
  produces.
- **`string` is not UTF-16 here.** FPC's default `string` is a byte string; the corpus is
  full of Cyrillic and Unicode punctuation. Byte-indexing a multi-byte character is the
  bug class to look for first in any new string handling.
- **Follow nesting iteratively where input depth is unbounded.** A recursive walk dies on
  deep input the reference handles — the same lesson the Python port paid for.
- **Sentinels U+E000–E005 are the engine's reserved range.** The `neutralize` safety
  restore is mandatory and survives `PostProcess=False`.

## Behavioral rules (base seed — expand as you work)

- **Think before coding.** State assumptions; if uncertain, ask. Present competing
  interpretations — don't pick silently. Name what's unclear and stop. Push back when a
  simpler path exists.
- **Simplicity first.** Minimum code that solves the problem — no speculative features,
  abstractions, flexibility, or error handling for impossible cases.
- **Surgical changes.** Touch only what the request needs; every changed line traces to it.
  Match existing style; don't refactor what isn't broken or delete pre-existing dead code
  (mention it). Remove only the orphans your change created.
- **Goal-driven + verify.** Turn the task into a verifiable goal; brief plan, per-step
  verification; confirm by an independent check, not assertion (see `proof-loop`,
  `code-review`). Here that check is the corpus runner, not a reading of the diff.
- **Chat answers: structured and plain.** Lead with the answer, then the why. No buzzwords.
- **Workspace hygiene.** Don't start background processes unless asked; clean up temp files
  and built binaries when done.
- **Don't block on a slow tool.** If a tool/MCP/server doesn't answer within a few seconds,
  proceed without it and say so.

Expand this section with project-specific behavioral lessons **only after a real incident** —
each line should trace to something that actually happened, not a guess. Behavioral lessons
go here; tool/skill/rule adaptations go to `REGISTRY.md`.

## Self-configuration (adapt and explain)

`~/.agents` provides a minimal shared baseline. Adapting to the project is standard work:

1. Local in `./.agents/` — already there? use it.
2. No → in the baseline `~/.agents/`? pull the chain (`cp` the rule + linked
   skills/agents/MCP), append to the local `./.agents/map.yaml` and to the pointer.
3. Not anywhere → escalation: the `research` domain (websearch → fetch → browser) to
   compare/find, install/attach into the project, append to the local map.

**Activate an agent by running it.** Claude's own config (`.claude/settings.json`, the
`CLAUDE.md` symlink) is present. codex and opencode render their own native config the
first time they run here — no agent sets up another agent's environment.

Accounting: `./.agents/map.yaml` = WHAT is attached. `./.agents/REGISTRY.md` = WHY.

Autonomy boundaries: adapting the PROJECT (layers 1–3) — without asking, standard;
changing the BASELINE `~/.agents` — only by agreement with the user.

**[CRITICAL] Any attach/install/replace — with an explanation in `REGISTRY.md`.**

## Commands

`fpc` 3.2.2+ required. `SPINTAX_FIXTURES` must point at the checked-out corpus.

- `sh ./build.sh` — build `tests/corpus_runner` and `examples/demo`.
- `./tests/corpus_runner "$SPINTAX_FIXTURES"` — the golden-corpus gate.
- `./examples/demo '[<sep=", ">fast|cheap|reliable] hosting'` — render demo.
- `fpc -Mdelphi -Sew -vw -Fusrc -FUlib -Cn src/Spintax.pas` — syntax/warning check only.

The pre-push git hook runs the build **and** the corpus, and **blocks** if
`SPINTAX_FIXTURES` is unset — a runner with no fixtures reports success over zero cases,
which is worse than a failure.

## Release

Not published yet. When it is: tag-driven, and **only on the user's explicit command**.
Never publish on your own initiative.

## Attached at initialization

- Library version: `dcef1f6` (2026-07-21) — see `.agents/generated/.agents.lock.yaml`
- Domains: `coding` (always-on `base` included on top)
- Rules: rule-format, env-setup, project-docs, proof-loop, secrets, git-discipline,
  quality-py, quality-js, quality-bash, quality-perl, quality-cpp, code-search,
  code-review, user-docs, **quality-pascal** (project-local, see REGISTRY)
- Agents: docs, searcher, reviewer
- Hooks: secrets-guard (PreToolUse), light-lint (PostToolUse), git-quality-gate
  (pre-commit / pre-push)
- MCP: none project-bound (playwright is machine-level global infra, used not rendered)

Links are read from `./.agents/map.yaml` — not duplicated here.
