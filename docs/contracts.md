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
- **[verified]** A `.prompt` command received during an active run is retained
  in the initial-turn queue. It starts a fresh generation after the current
  generation settles; it is never converted to steering or discarded.
- **[verified]** An internal run failure emits the synthesized assistant's
  terminal `message_finished`, then `failed`, and closes the generation with
  `run_finished(status: failed)`. This remains true when persisting the
  synthesized assistant also fails.
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

## CLI, settings, and non-interactive modes `[verified]`

- The Phase 2b parser accepts only `--cwd`, `--model`, `--thinking`,
  `-p`/`--print`, `--mode text|json`, `--resume`/`-r`, `--continue`/`-c`,
  `--no-session`, `--session-dir`, repeated `--config`, `--api-key`,
  `--tools`, `--no-tools`, `--system-prompt`, `--append-system-prompt`,
  `--version`/`-v`, and `--help`/`-h`. `--flag=value`, `--`, positional
  prompt ordering, and unknown-flag exit code 2 are test-covered. Help and
  version take precedence over other argument errors.
- Settings merge in this order: built-in defaults, global JSON, cwd-local
  project JSON, repeated JSON overlays, then runtime CLI values. Objects merge
  recursively; scalars and arrays replace the lower layer. A required overlay
  that is absent, malformed, or not an object is an error.
- API keys resolve from the runtime argument, then the models config, then the
  provider environment map. Key bytes are retained only for provider setup and
  the active run; they are never written to session, history, stdout, or
  stderr.
- Print and JSON modes drive `AgentSession.run` through the command inbox and
  consume only owned `AgentEvent` values from the outbox. `message_finished`
  owns the final assistant text blocks and optional error text needed by a
  frontend; no frontend reads the session message arena.
- Text mode writes only the last assistant message's text blocks. Final
  `error` or `aborted` messages flush stdout, write the error text to stderr,
  and return exit code 1. A final `run_finished(status: failed)` also returns 1
  even if no model-produced terminal message exists. JSON mode writes the
  canonical session header first, then exactly one JSON object per emitted
  event line, and returns 0 after flushing stdout.
- `--no-session`, custom session directories, newest-session continue, and
  path/id/filename-prefix resume are deterministic. A cross-project resume is
  declined without an interactive move/fork prompt. Empty CLI or configured
  model selectors remain unset. Submitted prompts append to
  consecutive-deduplicated JSONL history on a best-effort basis; dedupe reads
  only the last record and concurrent writers hold the file lock through the
  check and single-record write.
- A system-prompt argument is read as a file only when it names an openable
  file. Missing paths, non-directory components, invalid path names, and
  overlong path components leave the argument as literal prompt text; actual
  file read failures still propagate.

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
