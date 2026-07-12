# Porting guide: Pi coding agent (oh-my-pi) → Zig 0.16

The concrete design document for the port. It compresses the deep research
in [`docs/research/`](research/) into decisions and recipes. When a claim
here seems surprising, the research reports carry the file-level evidence;
when code is being written, the upstream sources in `inspiration/` are the
final authority.

Target: **oh-my-pi 16.4.7** (`inspiration/` pinned at `bb35e791`), the
`omp` coding agent. Dependencies (all commit-pinned in `build.zig.zon`):
ai.zig 0.1.0 (`128433a`), ZigZag 0.1.2 (`226dd3f`),
zig-quickjs-ng (`25836c5`, quickjs-ng 0.15.1).

---

## 1. Upstream anatomy, port order, scope

Upstream is ~470k handwritten TS + ~72k first-party Rust + ~98k vendored
Rust (full census: `research/inventory.md`). The dependency spine forces
the port order; the scope classification bounds it:

**Core — port** (in order): `hashline` (5.8k, self-contained, the edit
engine) → `utils` subset (dirs/paths, retry, frontmatter) → `catalog`
(~16k handwritten + models.json data; skip the ~85k generated protobuf
discovery) → `agent` (13.4k, the loop) → `coding-agent` in layers
(tools → session → modes → extensibility).

**Replaced by a Zig dependency**: `ai` (88k) → **ai.zig** (§4);
`tui` (25.5k) → **ZigZag** + custom components (§10); the eval JS worker
and TS extension host → **zig-quickjs-ng** (§11).

**Functionality-not-code** (Rust crates): walker/glob/grep, ANSI-aware
text width, PTY, process-tree kill, tokens, tree-sitter summaries — become
ordinary Zig modules as needed. The embedded brush shell + 45 vendored
coreutils (~135k) are **dropped**: v1 shells out to system `bash`/`sh`
(ledger L1).

**Deferred/skipped**: collab, stats dashboard, mnemopi/memory backends,
snapcompact, TTS/STT, browser/DAP/LSP tools, terminal-bench, ACP mode,
auth broker/gateway, python/ (external RPC consumers — kept only as a
future conformance corpus).

## 2. Layering

```
┌────────────────────────────────────────────────┐
│ frontends: tui (ZigZag) · print · json · rpc†  │
├──────────────── AgentCommand / AgentEvent ─────┤
│ core: AgentSession · loop · queues · approvals │
│ session: entries · JSONL store · manager       │
│ tools: registry · read/bash/edit/write/…       │
│ catalog · compact · js (QuickJS)               │
├────────────────────────────────────────────────┤
│ ai.zig: providers · streaming · schema · MCP   │
└────────────────────────────────────────────────┘        † phase 8
```

Directory layout: `src/core/`, `src/session/`, `src/tools/`,
`src/hashline/`, `src/catalog/`, `src/compact/`, `src/js/`, `src/modes/`,
`src/tui/`, `src/testkit/`, `src/prompts/` (embedded via `@embedFile`).
`src/root.zig` is the library root; `src/main.zig` the CLI.

## 3. The frontend contract

Two bounded mailboxes; owned payloads; no cross-layer callbacks:

```zig
pub const AgentCommand = union(enum) {
    prompt: OwnedPrompt,          // idle submit
    steer: OwnedPrompt,           // mid-run injection
    follow_up: OwnedPrompt,       // deliver at yield
    dequeue_last,                 // LIFO pop back to editor (alt+up)
    cancel: CancelReason,
    approve: ApprovalDecision,
    change_model: ModelSelection,
    change_thinking: ThinkingLevel,
    compact: ?OwnedText,          // optional instructions
    retry,
    shutdown,
};

pub const AgentEvent = union(enum) {
    run_started, run_finished: RunResult,
    turn_started, turn_finished: TurnResult,
    message_started: MessageStarted,
    text_delta: TextDelta, reasoning_delta: ReasoningDelta,
    message_finished: MessageFinished,
    tool_started: ToolStarted, tool_output: ToolOutputDelta,
    tool_finished: ToolFinished,
    approval_requested: ApprovalRequest,
    auto_compaction_started: CompactionReason,
    auto_compaction_finished: CompactionResult,
    auto_retry_started: RetryInfo, auto_retry_finished: RetryOutcome,
    usage_updated: UsageSnapshot,   // tokens, cost, context %
    notice: Notice,                 // level + message
    failed: OwnedError,
};
```

This mirrors upstream `AgentSessionEvent` minus deferred subsystems
(`research/coding-agent-core.md` §2.3). Rules: every payload is
**deep-copied into event-owned storage** before enqueue — never a borrowed
ai.zig stream slice (they are invalidated by the next pull). Frontends
never touch `AgentSession` state directly. Print/JSON modes are proof the
contract is complete: they consume the same events.

## 4. Using ai.zig: single-step streaming engine, client-executed tools

**Decision:** pi.zig owns the agent loop. ai.zig is invoked **one model
call at a time** — `streamText` with `stop_when = &.{ai.stepCount(1)}` and
tools passed **without `execute`** (an ai.zig `Tool` with `execute = null`
surfaces the call but does not run it). The port then runs its own tool
scheduler and builds the tool-result messages itself.

Why: Pi's loop semantics cannot be expressed inside ai.zig's loop —
steering boundaries, shared/exclusive tool concurrency, interruptible-tool
polling, inline approval prompts, `pause_turn` re-sampling, `length`-stop
placeholder pairing, unbounded steps (`research/agent-ai-mapping.md` §3.1).
What we lease from ai.zig per step: provider wire formats, SSE streaming,
retry engine (408/409/429/5xx, 2 retries), schema validation of tool
inputs, reasoning/thinking mapping, prompt-cache options, structured
output, MCP tool defs, and the canonical message codec.

Integration facts (verified, `research/ai-zig-surface.md`):

- Providers are built once per configured credential:
  `HttpClientTransport.init(gpa, io)` + factory (`anthropic`, `openai`,
  `openrouter`, `google`, `xai`, `openai_compatible`). No provider reads
  the environment implicitly; keys are injected (env lookup at the app
  layer). Compile out the bare-id default: `-Ddefault-openrouter=false`.
- Cancellation: run the step drive-loop under `io.async`; user interrupt =
  `future.cancel(io)`; the pipeline yields an `.abort` part; after the
  driver returns, `result.deinit(io)`. Tool code adds `io.checkCancel()`.
- Ownership: options/messages are **borrowed** by ai.zig for the call —
  session storage must outlive the stream. Results die at `deinit`; the
  session copies what it keeps via `message.cloneModelMessages(arena, …)`.
- Serialization: `provider.wire.stringifyAlloc/parse` round-trips
  `[]const ModelMessage` with upstream JSON tags — the session file's
  message core.

## 5. The loop (behavioral spec — reproduce exactly)

From `inspiration/packages/agent/src/agent-loop.ts` via
`research/coding-agent-core.md` §2 and `research/agent-ai-mapping.md` §1.4:

```
pendingMessages = dequeueSteering()                 // unless externally aborted
outer: while true:
  inner: while hasMoreToolCalls or pendingMessages:
    deadline check; pause-gate park
    inject pendingMessages (message events + context append)
    re-read live systemPrompt/tools/model/thinking      (per model call)
    resolve tool-choice directive once per logical turn
    assistant = one ai.zig step (§4)
    error|aborted stop → placeholder tool results for every call,
                         persisted assistant error message, end run
    runnable = stopReason in {toolUse, stop} && toolCalls.len > 0
    length-stop with calls → placeholder results, re-sample
    pause_turn with no calls → re-sample (max 8 consecutive)
    soft tool requirement: non-compliant turn → skip all calls with
      "Not executed: call the `X` tool …", force {tool,name} one turn
      (max 3 escalations)
    else execute tool batch (below)
    turn_end
    steering = dequeueSteering()                    // not on external abort
    pendingMessages = hasMoreToolCalls ? steering + asides : steering
  onBeforeYield; drain lateSteering + asides + followUps
  if any → pendingMessages, continue outer; else break
run finished
```

**Queue semantics (authoritative):** steering is consumed (a) at run
start, (b) after each tool batch fully settles, (c) at the yield-boundary
re-poll. Follow-ups only at the yield boundary. The mid-batch poll is
**non-consuming**. External abort never consumes; a drain-stranded-queue
pass schedules a fresh `continue()` afterwards. Modes: `steeringMode` /
`followUpMode` = `one-at-a-time` (default) | `all`; `interruptMode` =
`immediate` (default) | `wait`.

**Tool batch execution:** per-tool `concurrency: shared|exclusive|fn` —
shared run concurrently, an exclusive tool waits for everything before it
and blocks everything after. After each tool completes (plus a 250 ms poll
while any `interruptible` tool runs, when `interruptMode != wait`), a
non-consuming steering check runs; a hit aborts the batch's shared cancel
scope so remaining calls pair with skipped results ("Skipped due to queued
user message… retry the skipped tool if it is still needed"). Tool throws
become error results — never batch aborts; empty error content becomes
`"Tool failed with no output."`.

**Hard caps to reproduce:** `MAX_PAUSED_TURN_CONTINUATIONS = 8`,
`MAX_SOFT_TOOL_ESCALATIONS = 3`, steering poll 250 ms,
`UNEXPECTED_STOP_MAX_RETRIES = 3`, `EMPTY_STOP_MAX_RETRIES = 3`,
unexpected-stop backoff cap 8000 ms. Auto-retry of transient provider
errors: maxRetries 10, base 500 ms, cap 300 000 ms, model-fallback chains,
`fallbackRevertPolicy: cooldown-expiry`.

**Errors are data.** Provider failures/aborts terminate the run gracefully
with a persisted assistant message (`stopReason: error|aborted`,
`errorMessage`) and paired placeholder tool results — never an exception
to the frontend.

## 6. Message model and type mapping

The port defines its own `AgentMessage` (the upstream `convertToLlm` seam):

| Upstream (TS) | Zig |
| --- | --- |
| `Message` union (`user\|developer\|assistant\|toolResult`) + custom roles (`bashExecution`, `custom`, `branchSummary`, `compactionSummary`, `fileMention`) | `AgentMessage = union(enum)` with an envelope struct (timestamp ms, synthetic/steering flags, attribution, usage+cost, stopReason, errorMessage, model/provider stamps, `details` JSON, `useless`, `prunedAt`) |
| lowering to provider wire (`convertToLlm`) | `toModelMessages(arena) []ai.ModelMessage` — bash executions → user text blocks, `excludeFromContext` skipped, fileMention → developer `<file>` blocks (image parts split into user), summaries → templated user messages |
| `structuredClone` between layers | `ai.message.cloneModelMessages` / wire-codec round-trip |
| zod/arktype tool schemas | hand-written JSON Schema strings via `provider_utils.rawSchema` — field names/optionality/defaults byte-identical to the specs in `research/tools.md` |
| `AbortSignal` trees | `io.async` futures + per-batch cancel scope + atomic steering flags |
| `EventBus` / emitters | the two mailboxes (§3) + comptime callback tables internally |
| `Date.now()` | epoch ms via `std.time`; `Io.Timestamp` internally |
| `Bun.randomUUIDv7()` session ids | UUIDv7 generator (std PRNG + clock) |
| `Bun.hash.xxHash32` | `std.hash.XxHash32` (seed 0) |
| `bun:sqlite` (history.db, auth store, caches) | v1: none — JSONL history file (ledger L8); sqlite vendoring is a later decision |
| worker threads / IPC subprocesses | `std.Io` tasks + `std.process.Child` |

Ownership: the session's `AgentMessage` list is the single source of
truth, held in a session arena; per step it lowers to fresh borrowed
`ModelMessage` slices; step results are cloned in before `deinit`.

## 7. Session persistence

Format-compatible with upstream v3 (`research/coding-agent-core.md` §3;
`inspiration/docs/session.md` is normative):

- Path `~/.omp-zig/agent/sessions/<dir-encoded>/<timestamp>_<uuid7>.jsonl`
  (own config dir, ledger L9; dir-encoding algorithm kept).
- Line 0: fixed-width 256-byte mutable **title slot**; then header
  `{type:"session", version:3, id, timestamp, cwd, parentSession?, …}`;
  then entries `{type, id: 8-char, parentId, timestamp, …}` forming an
  **append-only tree with a mutable leaf pointer**. Entry union ported as
  a tagged union with wire tags (message, compaction, branch_summary,
  model_change, thinking_level_change, custom, custom_message, label,
  title_change, session_init, mode_change …).
- Pipeline guarantees: persistence deferred until the first assistant
  message; then full flush + incremental appends; atomic rewrites
  (temp+rename) for rename/prune/fork/migrations; `flushSync` on Ctrl+C;
  strings truncated at 500 000 chars with the exact upstream marker;
  base64 images ≥1024 chars externalized to the content-addressed blob
  store (`blobs/<sha256>`); lenient load, ENOENT → empty.
- Message payloads serialize their `ModelMessage` core through
  `provider.wire` plus the envelope fields (§6).

## 8. Compaction (phase 4)

v1 strategy `context-full` (upstream agent-core default; `snapcompact`
deferred, ledger L6). Port verbatim from
`inspiration/packages/agent/src/compaction/` + `docs/compaction.md`:

- Triggers: manual `/compact`, overflow recovery, incomplete-output
  (`length`) recovery, post-turn threshold, mid-turn boundary, idle.
- Threshold math: `effectiveReserve = max(floor(window*0.15), reserve
  16384)`; explicit tokens → clamp; percent → floor; else
  `window − reserve`. Context tokens = provider usage minus orchestration,
  floored by a local estimate (`(utf8len+3)>>2` v1; native cl100k later).
- Cut point: only entries after the previous compaction; **never cut at a
  toolResult**; split-turn → two summaries merged with the exact
  `**Turn Context (split turn):**` template. `keepRecentTokens` 20000.
- Pre-passes: prune tool outputs (protect newest 40k tokens, require
  ≥20k savings, never blank <50 tokens, exact `[Output truncated - N
  tokens]` / superseded / useless notices, blank-in-place pairing kept).
- Summary via one-shot ai.zig `generateText` with the upstream prompt
  files (embedded); `<conversation>` serialization rules kept (tool
  results head+tail 2000 chars @ 0.6, args caps 500/2000).

## 9. Catalog, usage, cost, auth

- `models.json` embedded (or a pruned build of it) parsed once into
  `Model` records: cost $/Mtok {input, output, cacheRead, cacheWrite},
  contextWindow, maxTokens, thinking config (mode, efforts, budgets,
  effortRouting), api, baseUrl. `calculateCost(model, usage)` ported;
  ai.zig `Usage` maps: input↔no_cache, cache_read/cache_write↔cacheRead/
  cacheWrite, output.total/reasoning↔output/reasoningTokens.
- Thinking levels `off|minimal|low|medium|high|xhigh|max` (+`auto` later):
  port owns the Effort→(adaptive|budget|effort-string) mapping tables;
  drive ai.zig via `reasoning` + `provider_options` (Anthropic budgets
  minimal 1024 → xhigh/max 32768; `max` maps per-provider, ledger L11).
- Model roles `default/smol/slow/plan/…` + fuzzy `--model` resolution +
  Ctrl+P cycle scope; per-role fallback chains feed the auto-retry layer.
- Auth v1: explicit API keys — CLI `--api-key` → models config → env var
  map (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, OPENROUTER_…,
  XAI_…). **OAuth flows, credential pools, rotation deferred** (ledger
  L4); the a/b/c rotation seam is "re-issue the step with a fresh key on
  auth failure", implementable above ai.zig later.

## 10. TUI on ZigZag

Verified base (`research/zigzag-verify.md`): Program/Terminal/unicode/input
layers are sound; the component layer is a parts bin. Design:

- **Manual loop**: `program.start()`, then per iteration drain the event
  mailbox → `program.send(.{ .agent = event })` (UI thread only — `send`
  is synchronous dispatch, confirmed), then `program.tick()`. No
  `AsyncRunner` (unsynchronized message list — a data race as written).
  60 fps pacing bounds mailbox latency at ~16 ms; a `Program.post`/wake
  upstream contribution removes even that (insertion points documented in
  zigzag-verify §13).
- **Ctrl+C**: ZigZag hardcodes quit-before-model. Phase 3 prerequisite: a
  fork adding `ctrl_c: enum { quit, forward }` (+ matching ctrl_z), pinned
  by commit; PR'd upstream in parallel. Pi semantics (flush → double-press
  500 ms → exit; single → clear editor; exit 130 while shutdown in flight)
  then live in the app.
- **TranscriptView (custom)**: unit = rendered block
  (`user|assistant|reasoning|tool|bash_execution|compaction|error`), each
  caching rendered rows, height, width, theme revision,
  collapsed/expanded, streaming flag. Blocks are **immutable once
  finalized**; exactly one blank separator row between blocks; expansion
  toggles invalidate and force full repaint. v1 presents an internal
  virtualized scroll (ledger L2 — upstream commits history to native
  terminal scrollback with no internal scrolling; the block contract keeps
  a future append-only presenter possible). ZigZag `VirtualList` is
  index/one-row-based — not used.
- **Markdown**: custom cached streaming renderer (ZigZag's re-walks the
  full source per frame and supports too small a subset). Re-render only
  the active block; coalesce deltas to ~30 fps; final render on finish.
  Target the upstream subset (`research/tui-spec.md` §2.3) minus LaTeX/
  mermaid/OSC-66 (ledger L10).
- **Editor**: ZigZag `TextArea` lacks undo/kill-ring/paste handling —
  custom composer: multiline, history, kill ring, undo, bracketed-paste
  collapse (>10 lines/1000 chars → `[Paste #N, +K lines]`), sigils
  (`!`/`!!`, `$`/`$$` later, `/`, `->`/`=>` queue shorthand, `.`/`c`
  continue), slash/file autocomplete.
- **Key ladders**: Esc ladder and Enter-while-streaming semantics ported
  exactly from `research/coding-agent-core.md` §6.4–6.6 (Enter = steer;
  empty Enter with queued messages = abort + drain; ctrl+q/ctrl+enter =
  follow-up; alt+up = LIFO dequeue).
- **Memory**: ZigZag `ctx.allocator` is frame-arena (reset per tick) —
  view output only. Persistent TUI allocator for blocks/caches/editor.
  Copy at the mailbox boundary; never hold ai.zig slices.
- Status/footer: model • thinking level, `↑in ↓out R W $cost ctx%`,
  cwd/git branch. Golden tests: (TuiModel + dims + AgentEvents + keys) →
  normalized frame + emitted AgentCommands, via ZigZag custom I/O files +
  snapshot normalization.

## 11. QuickJS layer

Verified base (`research/quickjs-bindings.md`): bindings are mature (165
tests, ~95% API coverage) but bring **no** std.Io integration, console,
timers, fetch, TextEncoder, or disk module loader — host work. Design:

- **JS executor**: one owner thread per `Runtime` (engine rule); runs
  evals, drains `executePendingJob` after every eval and host-promise
  settlement, checks cancellation between pumps, and bridges async host
  ops via promise capabilities resolved on the JS thread.
- **Cancellation/limits**: `setInterruptHandler` checks an atomic cancel
  flag + per-call deadline — interrupts synchronous loops in-process
  (upstream must kill its worker and lose state; we preserve state —
  ledger L5, an improvement). Uncatchable-exception harvest distinguishes
  "cancelled/timed out" from "threw"; `resetUncatchableError` before
  reuse. `setMemoryLimit`/`setMaxStackSize` per runtime.
- **eval tool** (phase 6): persistent context per session; `reset`
  recreates; cell semantics ported (final-expression capture, top-level
  await wrapper, `const/let/class` cross-cell persistence, `//# sourceURL`
  cell names) via a small rewrite pass; prelude (display/print/read/write/
  env/`tool.<name>()`/log/phase) as host closures; output through the
  shared OutputSink contract. v1: JS only, no npm resolution, no TS cells
  (ledger L7); `use_llvm = true` required on the exe.
- **Extension host** (phase 7): discovery paths + manifest rules ported;
  JSON-Schema tool parameters instead of zod (ledger L12); event dispatch
  with 30 s / 2 s timeout races, fail-closed `tool_call`, middleware
  `tool_result`; **declarative UI contract** (styled rows/markdown back to
  the host) instead of component objects (ledger L3).

## 12. Modes and CLI

- **Interactive** (default), **print** (`-p`/piped: final assistant text
  to stdout; `stopReason error|aborted` → message to stderr, exit 1),
  **json** (`--mode json`: header line then one `AgentEvent` JSON per
  line). RPC (NDJSON, `docs/rpc.md`) is phase 8; ACP deferred.
- Flag surface ported from `research/coding-agent-core.md` §1.3 in slices
  per phase (phase 2 minimum: `--cwd --model --thinking -p --mode
  --resume/-r --continue/-c --no-session --session-dir --api-key --tools
  --system-prompt --append-system-prompt --no-tools`). Exit codes: 0
  success/user-cancel, 1 error, 2 unknown flags, 130 double-SIGINT.
- Settings: global `config.yml` → project `.omp-zig/config.yml` → CLI
  overlays → runtime; defaults table from coding-agent-core §5.2 (approval
  mode default `yolo`, `edit.mode hashline`, `read.defaultLimit 300`,
  compaction reserve 16384 / keepRecent 20000, …).

## 13. Tools

Common plumbing first (`research/tools.md` §1): `AgentToolResult`
{content: text|image parts, details JSON, isError}; ToolError vs
ToolAbortError; approval tiers; concurrency flags; **the truncation core**
— `DEFAULT_MAX_LINES 3000`, `DEFAULT_MAX_BYTES 50 KiB`, column cap 768,
OutputSink tail window with artifact spill (head 20 KB/tail 20 KB/
tailLines 500) and the **exact notice strings** (`Showing lines A-B of N…`,
`Read artifact://<id> for full output`); timeout clamp table (bash
{300,1,3600}, eval {30,1,3600}, …).

Per-tool specs are re-implementation-grade in `research/tools.md`; v1
slices:

- **read**: local text + selector grammar (`:N`, `:A-B`, `:A+C`, lists,
  `:raw`), hashline headers `[anchor#TAG]` + `LINE:TEXT`, snapshot-store
  recording, structural summary deferred (plain reads with the standard
  limits), directories (depth 2/12 per dir), context expansion 1/3.
  Archives/SQLite/URLs/documents/images later.
- **bash**: one-shot `sh -c` via `std.process.Child`, merged
  stdout+stderr, non-interactive env hardening table, timeout
  kill-process-group, `(no output)` / `Command exited with code <n>` /
  `details.exitCode`; PTY + persistent shell + interceptor + auto-
  background later.
- **edit**: hashline mode **complete** — tag = `XxHash32(seed 0,
  trailing-ws-normalized) & 0xffff` upper-hex 4; ops SWAP/DEL/INS(.PRE/
  .POST/.HEAD/.TAIL)/REM/MV (block ops fall back to plain per the grammar
  until tree-sitter lands); lenient parser + exact rejection strings;
  snapshot store (LRU 30 paths × 4 versions, 64 MiB, 4 MiB/file cap);
  recovery: snapshot-diff replay (fuzz 0) → line-remap → session-chain;
  seen-lines guard with 40-line reveal; no-op guard (3 strikes); all-or-
  nothing multi-file with the applied/NOT-applied failure text.
- **write**: plain files + parent-dir creation, generated-file guard,
  hashline fresh-tag header on success; conflict/archive/SQLite later.
- **glob / grep** (phase 5): walker with gitignore, mtime sort, the exact
  caps/pagination (`skip`), `*LINE:` match format, per-file tag headers,
  30 s grep / 5 s glob timeouts with the exact texts.
- **todo** (phase 5): op union, state machine, auto-promotion,
  all-or-nothing error handling, `formatSummary`.
- **eval** (phase 6, §11). **task/subagents** (post-v1): nested
  AgentSessions in-process — the yield-tool protocol ported when it lands.

## 14. Build and packaging

- One `pi` module (root `src/root.zig`) + `omp-zig` exe (`src/main.zig`);
  imports: `ai`, `provider`, `provider_utils`, `anthropic`, `openai`,
  `openai_compatible`, `openrouter`, `google`, `xai`, `mcp` (from dep
  `ai`), `zigzag`, `quickjs` (+ `linkLibrary(artifact("quickjs-ng"))`,
  `use_llvm = true`).
- `zig build test` aggregates module+exe tests; `-Dtest-filter`
  supported; `-Dlive` gates network smokes (keys from `~/src/rctr/.env`).

## 15. Testing strategy

- **Upstream behavior is the spec.** The research reports quote exact
  constants, strings, and state machines — port them as table-driven Zig
  tests (loop boundaries, queue consumption, truncation notices, hashline
  corpus, selector grammar, threshold math, Esc ladder).
- Provider-free by default: a `testkit` mock `HttpTransport` (canned
  SSE/JSON) drives ai.zig end-to-end in-process; `std.testing.io`.
- Golden TUI tests via ZigZag custom I/O + frame normalization (the
  vendored package ships no test suite — ours lives in-tree).
- Hashline ports the upstream test corpus first (it is this port's
  fixJson: load-bearing and self-contained).
- Later: RPC conformance against `python/omp-rpc` fixtures.

## 16. Fidelity ledger (intentional deviations)

Track every deviation here; anything not listed is a bug.

1. **System shell instead of the embedded brush shell** + vendored
   coreutils. Bash tool = `sh -c` one-shot; rc-snapshot/persistent-session
   behaviors dropped; Windows loses the no-WSL story for now.
2. **Internal virtualized transcript scrolling** instead of upstream's
   append-only native-scrollback commit engine. Block immutability
   contract preserved so an append-only presenter can replace the
   TranscriptView later without touching the core.
3. **Declarative extension UI** (styled rows/markdown/dialog descriptors)
   instead of live component objects from extension JS.
4. **No OAuth in v1** (device/loopback flows, credential pools, rotation,
   broker/gateway). Explicit API keys only; Anthropic OAuth-token env
   accepted when trivial.
5. **QuickJS interrupt preserves interpreter state on cancel** (upstream
   force-kills the worker and loses all cells). Model-visible difference:
   variables survive an aborted cell.
6. **Compaction v1 = context-full**; snapcompact (bitmap frames) and
   remote/Codex compaction deferred. Handoff/shake later.
7. **eval v1 = JS only, no npm resolution, no TypeScript cells**; Bun
   globals replaced by host bindings; Python kernel (subprocess NDJSON)
   ports later unchanged in architecture.
8. **No SQLite in v1**: prompt history as JSONL; github cache, auth store,
   models cache deferred with their features.
9. **Own config/session root** (`~/.omp-zig/`) — no cohabitation with an
   installed omp; format-compatible session files.
10. **Markdown subset omits LaTeX→Unicode, mermaid, OSC 66 sized
    headings, DECCARA/SGR-coalescing optimizations** initially.
11. **Thinking `max` maps to the provider's nearest knob** (ai.zig
    `ReasoningEffort` tops at xhigh; Anthropic `effort: max` via
    provider_options where supported).
12. **Extension tool parameters are JSON Schema**, not zod/TypeBox/
    arktype shims.
13. **In-band tool-calling dialects (harmony/qwen3/kimi/…) not ported**
    initially; native tool-calling providers only.
14. **TTSR, advisor, goal/plan/vibe modes, skills, rules, memory tools,
    web tools, LSP/DAP/browser/github/ssh tools deferred** — the tool
    registry and event vocabulary leave room for each.
15. Download/URL fetch policy inherited from ai.zig for provider media;
    app-level web tools (when they land) carry their own allow/deny
    policy (hostname-vs-resolved-address gap documented there).
16. Hashline unseen-line previews preserve the upstream 512 UTF-16-code-unit
    budget but stop at a complete UTF-8 code point. At the exact boundary an
    astral character is omitted rather than emitting invalid UTF-8.
17. Hashline block resolution is injectable in Phase 0b, with no bundled
    tree-sitter resolver. `INS.BLK.POST` keeps the upstream plain-insert
    fallback; unresolved `SWAP.BLK`/`DEL.BLK` keep their upstream failure or
    preview-drop behavior. The resolver implementation lands with the later
    tree-sitter phase.
18. Hashline `Patch.parse` validates section bodies eagerly while the upstream
    `PatchSection` caches them lazily. Successful values and exact failure text
    match; malformed bodies fail during `Patch.parse`/`parseSingle` instead of
    the later `PatchSection.parse`/prepare call.
19. In-memory hashline snapshot `recorded_at` is a monotonic store tick rather
    than a wall-clock millisecond timestamp. LRU ordering, head/chain identity,
    and collision selection are preserved without adding a clock dependency.
20. Hashline semantic failures, including mismatches, return a tagged Zig
    `Failure` value rather than throwing a payload-bearing error object.
    `MismatchError` remains public for callers that need the structured fields;
    Patcher failures preserve its kind and byte-exact rendered message.

## 17. Phase-0 specifics (for the first implementation task)

Wire the three dependencies into `build.zig` exactly as §14; create the
directory skeleton with placeholder roots and one real vertical proof per
dependency: (a) an ai.zig type-level smoke (construct `GenerateTextOptions`
with defaults; construct an `openai_compatible` factory against the mock
transport), (b) a QuickJS link smoke (`Runtime.init` → eval `1+1` → `2` →
deinit, plus an interrupt-handler test), (c) a ZigZag import smoke
(reference `Program`/`Options` types; no terminal needed). `zig build
run -- --version` prints the version from build.zig.zon. All under
`zig build test`.
