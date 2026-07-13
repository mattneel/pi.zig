# Roadmap

**Status (2026-07-13):** research phase complete (`docs/research/`, nine
reports); porting guide and contracts drafted; **Phase 0 complete**
(deps wired, skeleton, three dependency smokes); **Phase 0b complete**
(hashline engine, 222/222 upstream corpus cases, adversarial review
fixes). **Phase 1 COMPLETE** — a headless agent that reads and edits real files
through a genuine model loop: 1a foundations (message model + lowering,
session entries, catalog, truncation core, approval table, events),
1b the loop (scheduler, mailboxes, raise/lower round-trip, AgentSession,
retry ladder), 1c the four essential tools (read, bash, edit, write) on
the tool.zig seam with an end-to-end read→snapshot→edit integration test.
**Phase 2 COMPLETE** — the core is provably frontend-agnostic and durable:
2a the session JSONL store (dir-encoded paths, title slot, entry tree +
mutable leaf, deferred/atomic persistence, truncation + blob store, lenient
load + v1→v3 migrations, resume) plus the gated `-Dlive` Anthropic smoke;
2b the CLI slice, JSON settings + precedence + defaults, key resolution +
provider construction, and print/JSON modes as pure `AgentEvent` consumers
with byte-exact goldens. Every subsystem multi-reviewed against upstream and
adversarially audited; 516/517 tests (1 gated live), green across seeds.
**Frontend switched ZigZag → tuizr (the maintainer's own TUI library, ledger
L68). Phase 3a COMPLETE** — the interactive TUI scaffold on tuizr: the drive
loop owns the tuizr `Terminal`, drains the `AgentEvent` outbox into a
`StreamingView` transcript + `TextInput` composer, renders the `CellGrid`, and
implements Pi's faithful Ctrl+C ladder (single clears the composer, double
within 500 ms quits; Escape cancels); byte-exact `CellGrid`-projection golden;
519 tests, green across seeds. **Next: Phase 3b — the block-structured
transcript widget + cached streaming markdown, built INTO tuizr as reusable
widgets (widget-ownership principle: generic UI → tuizr, agent glue → pi.zig).**

Phased implementation plan. Ordering is forced by the upstream dependency
spine (hashline → catalog → agent core → tools → session → modes → TUI →
compaction → QuickJS) plus one project constraint: the
`AgentCommand`/`AgentEvent` contract must stabilize before any frontend
lands (print/JSON prove it before the TUI consumes it). tuizr forwards all
input to the app, so no framework fork is needed and Pi's guarded Ctrl+C
ladder is implemented directly (ledger L68).

Every phase lands with tests derived from the upstream behavior specs
(exact constants/strings cited in `docs/research/`), and `zig build test`
green. Live-API smokes are opt-in (`-Dlive`, keys from `~/src/rctr/.env`).

---

## Phase 0 — Foundations

**Goal:** the skeleton everything else lands in.

- build.zig wiring per porting-guide §14: `ai` (all needed modules),
  `tuizr` (local-path dep; ZigZag was the original pick, since replaced),
  `quickjs` + `linkLibrary(artifact("quickjs-ng"))` +
  `use_llvm = true`; `-Ddefault-openrouter=false` forwarded to ai.zig.
- Directory skeleton (`src/core|session|tools|hashline|catalog|compact|
  js|modes|tui|testkit|prompts`), `root.zig` exports, `main.zig` with
  `--version`.
- Vertical proof smokes per dependency (porting-guide §17); testkit mock
  `HttpTransport` scaffold (canned SSE) proving an ai.zig `streamText`
  round-trip in-process.

**Accept:** `zig build test` green; `zig build run -- --version` prints
the zon version; the three dependency smokes pass offline.

## Phase 0b — hashline

**Goal:** the edit engine, self-contained, corpus-first (this port's
"fixJson").

- Tag algorithm (XxHash32 seed 0 & 0xffff, trailing-ws-normalized),
  format/tokenizer/lenient parser with the exact rejection strings, apply
  engine (all-or-nothing prepare/commit, bucket-by-anchor,
  boundary-echo repair), snapshot store (LRU 30×4, 64 MiB, 4 MiB/file),
  recovery ladder (snapshot-diff fuzz-0 → line-remap → session-chain),
  seen-lines guard, no-op guard, diff preview.
- Port the upstream hashline test corpus (packages/hashline tests +
  docs/tools/edit.md error tables).

**Accept:** corpus green, including recovery and rejection-string cases
byte-exact.

## Phase 1 — Agent core + the four essential tools (headless)

**Goal:** a working headless agent: prompt in, streamed events out,
steering, cancellation. (Sequence step 1.)

- `AgentMessage`/envelope + `SessionEntry` types + wire serialization;
  lowering (`toModelMessages`).
- The loop per porting-guide §5 over single-step ai.zig calls with
  client-executed tools; steering/follow-up/aside queues with the exact
  consumption boundaries; tool scheduler (shared/exclusive,
  interruptible, 250 ms polls, skip-with-placeholder); placeholder
  results for error/aborted/length; pause_turn ≤8; soft tool choice ≤3;
  errors-as-messages; auto-retry ladder.
- Approval resolution (tier × mode × per-tool policy, inline).
- Tools: `read` (v1 slice), `bash` (one-shot), `edit` (hashline, on 0b),
  `write` (plain files) — byte-exact output/truncation strings.
- Catalog v1 (embedded models data, cost, context windows, thinking
  tables); usage/cost accounting per message.
- `AgentCommand`/`AgentEvent` mailboxes; cancellation via `io.async` +
  future.cancel end-to-end (interrupt during model call AND during a
  tool batch).

**Accept:** loop-boundary/queue-consumption table tests green; mock-
transport multi-step tool runs reproduce upstream part ordering; a gated
`-Dlive` smoke streams a real Anthropic turn with a tool call; steering
mid-batch skips remaining tools with the exact skip text.

## Phase 2 — Print/JSON modes + persistence (frontend-independence proof)

**Goal:** sequence step 2 — the core is provably frontend-agnostic.

- Print mode (`-p`, piped stdin, exit codes, stderr contract) and JSON
  mode (header line + event-per-line) as pure `AgentEvent` consumers.
- Session JSONL store: title slot, header, entry tree + leaf, deferred
  persistence, atomic rewrites, flushSync, 500k truncation, blob
  externalization; `--resume/-r` (path/prefix), `--continue`,
  `--no-session`, `--session-dir`; prompt history (JSONL).
- CLI slice per porting-guide §12; settings files + precedence + the
  §5.2 defaults table.

**Accept:** print/JSON golden transcripts; session files round-trip
(write → load → identical tree/leaf/usage); a session written by the port
loads in a JSONL validator against upstream's documented format; kill
-9 mid-run loses at most the unflushed tail.

## Phase 3 — tuizr TUI (interactive parity for the daily loop)

**Goal:** sequence step 3. Frontend is **tuizr** (porting-guide §10). The
widget-ownership principle governs: generic UI is built INTO tuizr as reusable
widgets; pi.zig keeps only agent glue (drive loop, `AgentEvent`↔`AgentCommand`
mapping, Pi's key/Ctrl+C/sigil semantics).

- **3a — scaffold (COMPLETE).** pi.zig drive loop owns the tuizr `Terminal`,
  drains the `AgentEvent` outbox into a tuizr `StreamingView` (transcript) +
  `TextInput` (composer), renders the `CellGrid`, paces at ~60 fps via
  `io.sleep`. Faithful Ctrl+C ladder (single clears composer, double within
  500 ms quits; Escape → cancel; Ctrl+D → shutdown; release events filtered),
  approval auto-approve until Phase 5. Byte-exact `CellGrid`-projection golden +
  bridge/key unit tests; 519 tests, green across seeds.
- **3b — transcript + markdown (tuizr widgets).** The block-structured
  transcript as a tuizr `StreamingView` v2: typed blocks
  (`user|assistant|reasoning|tool|bash_execution|compaction|error`), per-block
  caches, immutable-once-finalized, one-blank-separator, internal virtualized
  scroll; a cached streaming-markdown widget (upstream subset minus LaTeX/
  mermaid/OSC-66). pi.zig maps each `AgentEvent` to a block.
- **3c — composer depth + chrome (tuizr widgets).** Extend `TextInput` into a
  rich editor (multiline, kill ring, undo, paste collapse, sigils, slash/file
  autocomplete); status line + footer + working loader; the full Esc ladder and
  Enter-while-streaming semantics; extend tuizr's input parser + `Key` enum for
  the richer keybindings.

**Accept:** widget-render tests in tuizr; pi.zig `CellGrid`-projection goldens
(streaming at bottom, scrolled-up, huge output, narrow terminal) + bridge/key
tests; documented manual acceptance on a real terminal for interrupt/steer/
queue flows.

## Phase 4 — Compaction + session operations

**Goal:** sequence step 4 — long sessions become practical.

- Compaction per porting-guide §8 (all six triggers, threshold math, cut
  points, pruning pre-passes, prompt files, auto-continue); `/compact`;
  overflow/incomplete recovery paths wired into the retry layer.
- `/new`, fork, branch (leaf move + rebuild), `/resume` picker, session
  list metadata reads, `/rename`, title auto-slot updates (tiny-model
  titling deferred — simple heuristic v1).

**Accept:** threshold/cut-point table tests; compaction round-trip
(compact → rebuild context → continue) on recorded fixtures; overflow
recovery retries and succeeds against the mock transport.

## Phase 5 — Tool & UI depth

**Goal:** sequence step 5.

- Tools: `glob`, `grep` (exact caps/pagination/formats), `todo` (+ HUD).
- Approval prompts in the TUI (tier/reason/details lines); tool cards
  with collapsed/expanded (ctrl+o) and diff rendering (±N| gutter,
  intra-line word diffs); slash commands (v1 set: /model /compact /new
  /resume /retry /settings-lite /exit + file-based commands); model
  selector + ctrl+p role cycling; thinking cycle (shift+tab).

**Accept:** renderer goldens per tool; grep/glob spec tables green.

## Phase 6 — QuickJS eval tool

**Goal:** sequence step 6 begins — the interpreter.

- JS executor (owner thread, job pump, promise bridging, timers);
  interrupt-based cancel/deadline; memory/stack limits; cell semantics
  (rewrite pass), prelude host bindings incl. `tool.<name>()` bridge into
  the session tool registry; OutputSink integration; `display()` protocol.

**Accept:** cell-semantics suite (final expression, TLA, cross-cell
persistence, reset, interrupt-preserves-state); tool-bridge round-trip;
runaway `while(true)` cancelled in <50 ms without losing the context.

## Phase 7 — Extensions (QuickJS host)

- Discovery/manifest rules, factory lifecycle, event dispatch (timeout
  races, fail-closed tool_call, middleware tool_result), registerTool/
  Command/Shortcut with JSON-Schema params, declarative UI contract,
  `sendMessage` deliverAs semantics.

**Accept:** a ported swarm-extension-style sample runs; event-contract
suite green.

## Phase 8 — RPC mode + breadth

- NDJSON RPC per `inspiration/docs/rpc.md` (ready frame, command set in
  slices, event forwarding); conformance run against `python/omp-rpc`
  fixtures.
- Breadth by demand: PTY bash + persistent shell, archives/SQLite/URL
  read, ast tools (tree-sitter), task/subagents, web_search, Python
  kernel, OAuth, remaining slash commands.

---

## Cross-cutting rules

- The **fidelity ledger** (porting-guide §16) is updated in the same
  change as any new deviation.
- Every phase ports the relevant upstream *behavior specs as tests*, not
  just code.
- Live tests opt-in only; never in default CI; keys via
  `~/src/rctr/.env` — never committed or printed.
- Upstream is re-pinned deliberately, with a diff review of
  `packages/agent` and `packages/hashline` first (loop and edit-engine
  changes ripple furthest).
- Implementation goes through codex tasks (one thread per task); Claude
  plans, reviews `git diff`, runs the acceptance commands, and commits
  when green.
