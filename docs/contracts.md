# Behavioral contracts and sharp edges

What the implementation actually guarantees. Statements here must be
verified against code and tests before they graduate from **planned** to
**verified**; items not yet nailed down are marked **open**. When behavior
deviates from upstream deliberately, it is also in the porting guide's
fidelity ledger (§16).

Status legend: `[planned]` designed, not yet implemented · `[verified]`
implemented and test-covered · `[open]` undecided.

## Loop and queues `[planned]`

- Steering is consumed at exactly three points: run start, after a tool
  batch fully settles, and the yield-boundary re-poll. Follow-ups only at
  the yield boundary. The mid-batch poll never consumes. External abort
  never consumes; stranded queued messages schedule a fresh continue.
- Tools run iff `stopReason ∈ {toolUse, stop}` and the message has tool
  calls. `length` never executes calls (placeholder results, re-sample).
  `pause_turn` with no calls re-samples, max 8 consecutive.
- Every tool call is always paired with a result — real, error, skipped,
  or placeholder — before the next model call. No dangling calls, ever.
- A tool failure is data (error result), never a batch abort. Empty error
  content becomes `"Tool failed with no output."`.
- Provider errors/aborts end the run with a persisted assistant message
  (`stopReason: error|aborted`) — frontends never see an exception.
- An exclusive tool serializes against the whole batch; shared tools run
  concurrently; results are assembled in call order.

## Cancellation `[planned]`

Three layers, matching ai.zig's model:
1. Frontend cancel (Esc) is delivered as a mailbox command from any
   thread; the core cancels the step future (`future.cancel(io)`).
2. In-flight I/O cancels at its next cancellation point; the stream
   yields an `abort` part; cleanup runs both the acknowledged and the
   completed-anyway cases.
3. Tool code is cooperative (`io.checkCancel()` at loop points); a
   cancelled tool may still finish later — its effects can land after the
   run reported aborted. QuickJS cells are the exception: the interrupt
   handler stops synchronous JS in-process, state preserved (ledger L5).

## Session persistence `[verified]`

- Append-only entry tree with a mutable leaf pointer; entries are never
  rewritten in place except the fixed-width title slot. Full-session rewrites,
  including migration rewrites, use a temporary file and atomic replacement;
  rename, prune, and fork orchestration is deferred (ledger 56).
- Nothing is persisted before the first assistant message exists.
- Agent shutdown drains and synchronizes the writer. `flushSync()` synchronizes
  an already-current file and performs a full synchronous rewrite only when a
  migration or other pending rewrite requires one. A hard kill loses at most
  the unflushed tail, never corrupts earlier lines (JSONL, lenient load).
- Strings > 500 000 chars are truncated with the upstream marker; base64
  images ≥ 1024 chars live in the content-addressed blob store.
- The `ModelMessage` core of every message entry round-trips through
  ai.zig's canonical wire codec byte-stably.

## Model-facing byte parity `[planned]`

The following are byte-exact against upstream and locked by tests:
hashline tags/headers/rejection texts; read `LINE:TEXT`/`LINE|TEXT`
prefixes and selector errors; grep `*LINE:` format; truncation notices
(`Showing lines A-B of N…`, `Read artifact://<id> for full output`,
`[Output truncated - N tokens]`, superseded/useless notices); bash
`(no output)` / `Command exited with code <n>`; tool-skip text
(`Skipped due to queued user message…`); soft-tool-choice reminder text.

## TUI threading `[planned]`

- `Program.send` is UI-thread-only; the agent publishes owned events into
  a bounded mailbox drained by the UI loop before each `tick()`.
- Event payloads are deep-copied at the core boundary; no ai.zig stream
  slices or session-arena pointers ever enter a mailbox.
- Frame-arena allocations (`ctx.allocator`) never outlive a tick;
  transcript blocks/caches live on the persistent TUI allocator; blocks
  are immutable once finalized.
- Tool output has three representations: canonical (session/artifact),
  TUI-live (bounded ring), model-visible (Pi truncation policy).

## Approvals `[planned]`

Inline resolution per call: tool decision (tier|fn) → per-tool user
policy (`allow|deny|prompt`) → mode tier (always-ask=read, write=write,
yolo=all). `override:true` force-prompts except in yolo; `deny` blocks
with an error result. Subagents (when they land) run yolo behind the
parent `task` approval boundary.

## Open items

- **[open]** SQLite adoption point (prompt history FTS, caches) — v1
  ships JSONL history (ledger L8).
- **[open]** Session-file interop guarantee level with upstream omp
  (read-compatible? bidirectional?) — currently: same format, separate
  root (`~/.omp-zig/`), no cohabitation claim.
- **[open]** ZigZag upstreaming: ctrl_c option and post/wake accepted
  upstream vs long-lived fork.
- **[open]** Windows support tier (ConPTY bash, suspend semantics).
- **[open]** Duplicate tool-call ids within one response (inherits
  ai.zig's last-write-wins; needs a defined contract + test here too).
- **[open]** Whether print mode replays `AgentEvent`s from a `--resume`d
  session or always starts a fresh run (match upstream when reached).
