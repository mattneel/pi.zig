# AGENTS.md — pi.zig

Instructions for all agents working in this repository.

## Objective

An **independent, parity-focused Zig 0.16 implementation of the Pi coding
agent** (upstream: oh-my-pi's `omp`), built on:

- **ai.zig** — providers, streaming, tool-call plumbing, structured output,
  MCP (pinned dep `ai`; sibling repo at `~/src/zig/ai.zig`)
- **ZigZag** — terminal UI (pinned dep `zigzag`)
- **zig-quickjs-ng** — extension scripting + the `eval` tool's JS runtime
  (pinned dep `quickjs-ng`)

everything on Zig 0.16's `std.Io`.

"Parity" is tiered, and the tiers are the contract (docs/porting-guide.md
§1 + §18): **behavioral parity** for the agent loop, session format, and
tool semantics (upstream behavior specs ported as Zig tests); **byte
parity** for model-facing strings (tool output formats, truncation
notices, error texts — models are steered by these exact bytes);
**conceptual parity** for CLI/UX; **intentional adaptations** itemized in
the fidelity ledger; and an explicit **deferred/unsupported list**. Do not
describe this project as a "1:1 port". When you deviate, ledger it; when
you can't decide, match upstream.

## Non-negotiables

1. **Do not skip or stub concurrency, streaming, steering, or
   cancellation because it is difficult.** Mid-run steering, tool-batch
   interruption, and clean cancellation are the product. A port that only
   does blocking request/response is a failure.
2. **Byte-exact model-facing strings.** Tool result formats, truncation
   notices, hashline tags/headers, and error messages are quoted in
   docs/research/tools.md. Reproduce them exactly; they are load-bearing
   prompt engineering, not cosmetics.
3. **Compiler errors are signal, not noise.** Zig 0.16 rejecting your code
   is directing you to read the stdlib source and learn the current idiom.
   Do not downgrade the approach or hand-wave with `anyopaque`.
4. **The stdlib source is the documentation.** `std.Io` is thinly
   documented online and training data is stale. Read `std/Io.zig`,
   `std/Io/`, `std/http/` from the pinned compiler (see Toolchain).
5. **The agent core knows nothing about the TUI.** Dependency direction is
   `pi core ← frontends`; the only coupling is the `AgentCommand` /
   `AgentEvent` mailbox contract (docs/porting-guide.md §3). Never leak
   ZigZag types, terminal state, or rendering concerns into `src/core/`.

## Toolchain: anyzig

The `zig` on PATH is **anyzig**: `zig <cmd>` resolves the version from
`.minimum_zig_version` in `build.zig.zon` (this repo pins **0.16.0**).
`zig env` prints where the real compiler lives (`.std_dir` is the stdlib
source — read code there for idioms; re-derive it, never hardcode it).

Zig 0.16 reference corpus: `/mnt/c/src/zig-corpora/` — release notes
(UTF-16LE; `iconv -f UTF-16LE -t UTF-8` before grepping; read *Juicy Main*
and *I/O as an Interface*), the full ziglang source tree, and real-world
0.16 codebases.

## Reference material

- `inspiration/` — **oh-my-pi vendored read-only** (pinned `bb35e79`,
  v16.4.7). The porting source of truth. Key paths:
  `packages/agent/src/agent-loop.ts` (the loop), `packages/coding-agent`
  (tools/session/modes), `packages/hashline` (edit engine), `docs/*.md`
  (73 behavioral spec docs). **Never modify anything under
  `inspiration/`.** Upstream tests and docs encode the behavioral
  contract — read them before porting a unit.
- `docs/research/` — nine deep research reports with file-level evidence
  (inventory, coding-agent-core, agent-ai-mapping, tools, tui-spec,
  extensions-interpreter, zigzag-verify, quickjs-bindings,
  ai-zig-surface). **Read the relevant report before designing anything.**
- `docs/porting-guide.md` — the concrete design doc; read before writing
  code. `docs/roadmap.md` — phased plan; work follows phases in order.
  `docs/contracts.md` — behavioral guarantees the implementation makes.
- `~/src/zig/ai.zig` — the AI layer we build on; its `docs/book/` and
  `docs/contracts.md` govern usage patterns (ownership, cancellation).
- `zig-pkg/` — local mirrors of the three pinned dependencies for offline
  grepping. Builds fetch by url+hash from `build.zig.zon`; never edit
  `zig-pkg/`.

## Working rules

- Every ported unit ships with tests derived from upstream behavior
  (specs in docs/research/ cite exact upstream constants and strings —
  those become test assertions).
- Any intentional deviation from upstream is recorded in the fidelity
  ledger (docs/porting-guide.md §18) **in the same change**.
- `zig build test` must pass before any commit.
- No third-party Zig dependencies beyond the three pinned ones without
  prior discussion. The stdlib is the default answer.
- Prompt/template text is embedded via `@embedFile` from `src/prompts/`,
  never inline string literals (upstream rule, kept).
- Live-API smoke tests are opt-in (`-Dlive`) and read keys from
  `~/src/rctr/.env` (`export`-format). Never commit, copy, or print
  key values.
- Describe defects and behavior in plain functional terms in code,
  comments, and commit messages (e.g. "a data race", "access after
  cleanup", "the download URL allow/deny policy").
