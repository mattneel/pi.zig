# Pi Coding Agent (oh-my-pi) — Agent-Core Behavioral Spec for the Zig Port

Source tree: `/home/autark/src/zig/pi.zig/inspiration` (Bun/TS monorepo `@oh-my-pi/*`, version 16.4.7).
Main package: `packages/coding-agent` (`bin: { "omp": "src/cli.ts" }`). Agent loop core: `packages/agent` (`@oh-my-pi/pi-agent-core`). All paths below are relative to the repo root unless absolute.

---

## 1. Entry point + CLI surface

### 1.1 Binary and constants

- Binary name: **`omp`** (`APP_NAME = "omp"`, `packages/utils/src/dirs.ts:20`); config dir name `.omp` (`CONFIG_DIR_NAME = ".omp"`, dirs.ts:23). Agent home: `~/.omp/agent` (relocatable via `PI_CODING_AGENT_DIR`; `PI_CONFIG_DIR` renames `.omp`; profiles land in `~/.omp/profiles/<name>`).
- Entry: `packages/coding-agent/src/cli.ts`. Startup order (cli.ts:261-341):
  1. Strip `MallocStackLogging*` env vars (macOS quirk).
  2. Enforce minimum Bun version (from package.json `engines.bun`, ≥1.3.14); on failure write `error: Bun runtime must be >= …` to stderr, exit 1.
  3. `process.title = "omp"`.
  4. `extractProfileFlags` pre-parses `--profile <name>` / `--alias <name>` before anything reads env (`.env` load ordering constraint). No explicit `--profile` → activate `OMP_PROFILE`/`PI_PROFILE`. `--alias` writes a shell alias and exits.
  5. Worker-thread re-entry: if `argv[0]` starts with `__omp_worker_` dispatch to embedded worker entrypoints (`__omp_worker_tiny_inference`, `__omp_worker_stats_sync`, `__omp_worker_tab`, `__omp_worker_js_eval`, `__omp_worker_stt`, `__omp_worker_tts`, `__omp_worker_mnemopi_embed`) and return. (Bun-ism; see §8.)
  6. `--smoke-test` hidden flag: spawn all bundled workers + stats dashboard, print `smoke-test: ok`.
  7. `resolveCliArgv` (src/cli-commands.ts:113): `--help/-h/--version/-v/help` pass through; a registered subcommand as argv[0] dispatches; a subcommand hidden behind leading global flags is hoisted to front (`omp --approval-mode=yolo acp` works); reserved bare words `extensions`, `list`, `remove` (argc==1) produce a hard error message pointing at `omp plugin …` (exit code 1); everything else is rewritten to `["launch", ...argv]` — i.e. free text becomes the prompt.

### 1.2 Subcommands (src/cli-commands.ts:14-47)

`launch` (default/root), `acp`, `auth-broker`, `auth-gateway`, `agents`, `bench`, `commit`, `completions`, `__complete` (hidden completion helper), `config` (list/get/set/reset/path — see §5), `dry-balance`, `gc`, `grep`, `gallery`, `grievances`, `install`, `join <link>`, `models`, `plugin`, `say`, `setup`, `shell`, `read`, `ssh`, `stats`, `update`, `usage`, `tiny-models`, `token`, `ttsr`, `worktree` (alias `wt`), `search` (alias `q`).

### 1.3 Launch flags (single source of truth: `src/cli/flag-tables.ts` + `src/cli/args.ts`)

String-value flags (always consume next token, even flag-looking, except the profile boundary sentinel `--omp-profile-boundary`):
`--cwd`, `--config` (repeatable overlay), `--mode <text|json|rpc|acp|rpc-ui>`, `--fork <id|path>`, `--provider`, `--model` (fuzzy; `provider/pattern` or `pattern`; `:thinking` suffix allowed), `--smol`, `--slow`, `--plan` (extension-shadowable), `--max-time <seconds>` (sets absolute deadline = now + s*1000), `--api-key`, `--system-prompt` (text or file), `--append-system-prompt`, `--provider-session-id`, `--prompt-cache-key`, `--session-dir`, `--models a,b,c` (Ctrl+P scope), `--tools a,b` (validated against `BUILTIN_TOOL_NAMES`; unknown names warn + drop; legacy aliases `search`→`grep`, `find`→`glob`), `--thinking <off|minimal|low|medium|high|xhigh|max|auto>`, `--export <session.jsonl> [out.html]` (export then exit 0), `--hook` (repeatable), `--extension`/`-e` (repeatable; Windows multi-token path re-joining logic args.ts:103-125), `--plugin-dir` (repeatable), `--skills a,b`, `--approval-mode <always-ask|write|yolo>`.

Optional-value flags: `--resume` / `-r` / `--session` — bare form = `true` (picker), value form = session id-prefix/filename-prefix/path; `rejectEmpty: true` (an empty string is treated as bare).

Boolean flags (`VALUELESS_FLAGS`): `--help/-h`, `--version/-v`, `--allow-home`, `--continue/-c`, `--no-session`, `--no-tools`, `--no-lsp`, `--no-pty`, `--hide-thinking`, `--advisor`, `--print/-p`, `--print-thoughts`, `--no-extensions`, `--no-skills`, `--no-rules`, `--no-title`, `--auto-approve`, `--yolo`.

Parsing details the port must reproduce:
- `--flag=value` is split by splicing the value as the next token; if a boolean flag doesn't consume it, the token is deleted so it never becomes a positional (args.ts:159-165, 276-278).
- `--` = POSIX end-of-options; all later tokens are literal messages. Lone `-` passes through as a message.
- `@path` positionals are file arguments; surrounding single/double quotes on the path are stripped. Files become prompt-attached content (`processFileArguments`; images auto-resized per `images.autoResize`).
- Extension-registered flags shadow same-named built-ins and are collected into `unknownFlags`; after extensions load, a reparse validates; any remaining flag-shaped token is a hard error: `Error: unknown flag(s): …` + `Run \`omp --help\`…`, **exit code 2** (main.ts:1339-1348, args.ts:290-300).

### 1.4 Run modes

Mode resolution (main.ts:1084-1089): protocol modes = `rpc`, `rpc-ui`, `acp` (own stdin; piped-input read is skipped). Otherwise stdin-not-a-TTY → read all of stdin as the prompt (`readPipedInput`, 1s notice `Reading prompt from piped stdin (waiting for EOF; ctrl+c to abort)…` on stderr); piped input with neither `-p` nor `--mode` ⇒ `autoPrint` (behaves as print). `isInteractive` = not print, not autoPrint, no `--mode`.

- **Interactive TUI** (default): `runInteractiveMode` (main.ts:396-518) — InteractiveMode init, optional setup wizard (`setupVersion` < `CURRENT_SETUP_VERSION` or forced), optional startup splash, changelog display when version changed (marker file stores last-seen version), background npm version check (`https://registry.npmjs.org/@oh-my-pi/pi-coding-agent/latest`, 5s timeout, gated by `startup.checkUpdate`), then initial prompt(s), then loop `while(true){ input = await mode.getUserInput(); await submitInteractiveInput(mode, session, input); }`.
- **Print mode** (`-p` / piped): `src/modes/print-mode.ts`. Sends `initialMessage` then each extra message sequentially via `session.prompt`. `--mode text` (default): prints final assistant message's text blocks (and thinking blocks if `--print-thoughts`) to stdout; a final `stopReason === "error"|"aborted"` message prints its `errorMessage` to stderr and **exits 1** (after telemetry flush + stderr drain). `--mode json`: first line = session header JSON, then every `AgentSessionEvent` as one JSON per line on stdout; startup notices go to stderr (`writeStartupNotice`, main.ts:98-100). Flushes stdout, disposes session, exits 0.
- **RPC mode** (`--mode rpc` / `rpc-ui`): newline-delimited JSON over stdio (docs/rpc.md, `src/modes/rpc/rpc-mode.ts`). Writes `{"type":"ready"}` first. stdin frames: `RpcCommand`, `extension_ui_response`, `host_tool_update|host_tool_result`, `host_uri_result`. stdout frames: `response`, all `AgentSessionEvent`s, `extension_ui_request`, `host_tool_call|host_tool_cancel`, `host_uri_request|host_uri_cancel`, `extension_error`, `available_commands_update`, `prompt_result`, subagent frames, `command_output`/`session_info_update`/`config_update`. Full command set (rpc-types.ts): prompting `prompt` (with `streamingBehavior?: "steer"|"followUp"`), `steer`, `follow_up`, `abort`, `abort_and_prompt`, `new_session`; state `get_state`, `get_available_commands`, `set_todos`, `set_host_tools`, `set_host_uri_schemes`, `set_subagent_subscription`, `get_subagents`, `get_subagent_messages`; model `set_model`, `cycle_model`, `get_available_models`; thinking `set_thinking_level`, `cycle_thinking_level`; queues `set_steering_mode`, `set_follow_up_mode`, `set_interrupt_mode`; compaction `compact`, `set_auto_compaction`; retry `set_auto_retry`, `abort_retry`; bash `bash` (concurrent; correlate by id), `abort_bash`; session `get_session_stats`, `export_html`, `switch_session`, `branch`, `get_branch_messages`, `get_last_assistant_text`, `set_session_name` (empty → error `Session name cannot be empty`), `handoff`; `get_messages`; login `get_login_providers`, `login`. Responses `{ id?, type:"response", command, success, data?|error }`; `prompt` acks immediately, completion signaled by `agent_end` or `data.agentInvoked:false`/`prompt_result`. Unknown commands and parse failures answer with `id: undefined` (`command:"parse"` for parse errors) and the loop continues. stdin close ⇒ reject pending host calls, **exit 0**. RPC/ACP modes: `@file` args rejected (exit 1), `PI_NO_TITLE=1` forced, host-neutral setting defaults re-applied for `task.*`, `memory.*`, `advisor.*`, `tier.advisor` (+`async.*`, `bash.autoBackground.*` for RPC) unless explicitly configured (main.ts:127-179).
- **ACP mode** (`--mode acp` or `omp acp`): Agent Client Protocol server; per-`session/new` factory (`createAcpSessionFactory`, main.ts:364-394) re-clones settings for the client cwd, always `enableMCP:false` (client supplies MCP servers), `hasUI:false`.

### 1.5 Exit codes

0 = success / user-cancel paths (`No session selected`, resume declined); 1 = errors (unknown session, no model/API key, export failure, print-mode assistant error, invalid profile); 2 = unrecognized flags; 130 = second Ctrl+C while shutdown already in flight.

### 1.6 Session-resolution flags (startup) — `createSessionManager` (main.ts:638-748)

- `--fork <src>`: incompatible with `--no-session` (error). Values containing `/`, `\`, or ending `.jsonl` are paths; else resolved via `resolveResumableSession` (case-insensitive prefix on session id, filename, or id-suffix after `<timestamp>_`). Not found ⇒ `Session "x" not found.` + hint, exit 1.
- `--no-session`: `SessionManager.inMemory()`.
- `--resume <val>`: open by path or resolved match. Local match whose recorded cwd no longer exists ⇒ interactive `[Y/n]` prompt to move (re-root) it into current dir; global match from a different project ⇒ move prompt then `[y/N]` fork prompt; non-interactive ⇒ friendly error. Decline ⇒ notice `Resume cancelled: session is in another project.` exit 0.
- `--resume` bare: session picker over the cwd's sessions; if none, probe globally (never auto-switch scope, only pre-load for the picker's Tab). Selecting a session from another project chdirs into it (`setProjectDir`), clears plugin/capability caches, reloads settings for that cwd.
- `--continue`: `SessionManager.continueRecent` — terminal breadcrumb first, else newest mtime in the cwd's session dir; includes moved-project re-rooting heuristics (session-manager.ts:2003-2071).
- `--session-dir` alone: create new session there.
- Setting `autoResume: true`: behaves like `--continue` when a prior session exists (and then treats it as continue for model restoration).
- Resuming with dangling tool calls logs + shows warning (`describePendingToolCalls`).

---

## 2. Session model (in-memory) — run/turn structure, steering, queueing

### 2.1 Agent core state (`packages/agent/src/agent.ts`, `types.ts`)

`AgentState` = `{ systemPrompt: string[], model, thinkingLevel?, disableReasoning?, tools: AgentTool[], messages: AgentMessage[], isStreaming, streamMessage, pendingToolCalls: Set<string>, error? }`.

`AgentMessage` = wire `Message` (`user` | `assistant` | `toolResult` | `developer`) ∪ app-registered custom roles (declaration merging, `src/session/messages.ts:596-606`): `bashExecution`, `pythonExecution`, `custom` (customType, content, display, details, attribution, timestamp), `hookMessage` (legacy), `branchSummary`, `compactionSummary`, `fileMention`.

`convertToLlm` (messages.ts:724-839) maps them for the provider: bash/python executions → user text (```Ran \`cmd\`\n```…, exit code, cancellation notes); skipped entirely when `excludeFromContext` (the `!!`/`$$` prefixes); `fileMention` → developer message with `<file path="…">…</file>` blocks (image files split into a user message because only user content accepts images on Responses); `custom` → developer message (user message if it is a user-invoked skill prompt; image-bearing customs are split); `branchSummary`/`compactionSummary` → user messages rendered through static templates (`packages/agent/src/compaction/prompts/compaction-summary-context.md`, `branch-summary-context.md`).

Events (`AgentEvent`): `agent_start`, `turn_start`, `message_start/ message_update(assistantMessageEvent)/ message_end`, `tool_execution_start/ tool_execution_update/ tool_execution_end`, `turn_end{message,toolResults}`, `agent_end{messages}`.

### 2.2 The loop (`packages/agent/src/agent-loop.ts:755-1186`) — must be reproduced exactly

```
pendingMessages = dequeueSteering()            // pre-run check (unless externally aborted)
outer: while true:
  inner: while hasMoreToolCalls or pendingMessages:
    (deadline check; pause-gate park; turn_start except first)
    inject pendingMessages (message_start+message_end each; append to context)
    syncContextBeforeModelCall (re-read live systemPrompt/tools)
    resolve tool-choice directive once per logical turn (hard ToolChoice | SoftToolRequirement)
    message = streamAssistantResponse(...)     // model call; getModel/getReasoning re-read per call
    if stopReason error|aborted:
        pair every toolCall with an aborted placeholder toolResult;
        turn_end; agent_end; return
    toolCalls = non-cursor-resolved toolCall blocks
    runnable = stopReason in {toolUse, stop}; hasMoreToolCalls = runnable && toolCalls.length>0
    soft-requirement gate: a non-compliant turn gets all calls skipped
        ("Not executed: call the `X` tool …"), forcedToolChoice next turn (max 3 escalations)
    else executeToolCalls(...)                 // see below
    stopReason length with toolCalls → placeholder results, then hasMoreToolCalls = true (re-sample)
    pause_turn stop-details with no tool calls → re-sample (max 8 consecutive)
    turn_end (onTurnEnd hook awaited unless aborted/errored)
    steering = dequeueSteering()               // NOT drained when externally aborted
    pendingMessages = hasMoreToolCalls ? steering + resolveAsides(getAsideMessages())
                                       : steering
  onBeforeYield()
  lateSteering + asides + followUps = drain; if any → pendingMessages, continue outer
  break
agent_end
```

`executeToolCalls` (agent-loop.ts:1770+): tool batch executes with per-call records; after each tool a **non-consuming** steering poll (`hasSteeringMessages`, cadence 250ms for `interruptible` tools) runs when `interruptMode !== "wait"`; queued steering aborts the shared batch signal so remaining calls are skipped with placeholder results ("skipped" tool results), but the queue keeps its messages until the injection boundary dequeues them. IRC interrupts only abort tools marked `interruptible`. Tool results are coerced/validated (`coerceToolResult`) — malformed results become error results; empty error content becomes `"Tool failed with no output."`; `useless` flag survives only when not an error.

Queue semantics (`Agent`, agent.ts:328-975):
- `steer(msg)` → steering queue; delivered mid-run at next boundary; skips remaining tools when interrupting.
- `followUp(msg)` → follow-up queue; delivered only when the agent would otherwise stop.
- `steeringMode` / `followUpMode`: `"one-at-a-time"` (default) dequeues 1 per boundary; `"all"` drains the whole queue at once.
- `interruptMode`: `"immediate"` (default) / `"wait"`.
- `prompt()` throws `AgentBusyError` while streaming. `continue()` when tail is assistant: dequeue steering (skipInitialSteeringPoll so it isn't double-dequeued) else follow-up else throw; otherwise `agentLoopContinue` (tail must convert to user/toolResult).
- `popLastSteer()` / `popLastFollowUp()` — LIFO dequeue for the Alt+Up "dequeue back into editor" key.
- Abort: `agent.abort(reason)`; external abort leaves both queues intact — the session-level `#drainStrandedQueuedMessages` schedules a `continue()` afterwards so a queued steer resumes in a fresh run.
- On abort/error the loop synthesizes an assistant message `stopReason:"aborted"|"error"` with `errorMessage` (Anthropic "Output blocked by conten…" errors emit a *visible* partial assistant message instead).

### 2.3 Session layer (`packages/coding-agent/src/session/agent-session.ts`)

`AgentSession.isStreaming` = `agent.state.isStreaming || promptInFlightCount>0` (line 6009).

`AgentSession.prompt(text, options)` (line 7640): order of operations —
1. If text starts `/`: extension commands run immediately (even while streaming); then custom TS commands (may return replacement prompt text or fully handle); then markdown file-based slash-command expansion.
2. Prompt-template expansion; magic keywords (`ultrathink`, `orchestrate` …) append hidden notices (skipped for synthetic prompts).
3. **If streaming**: requires `options.streamingBehavior` (`"steer"`|`"followUp"`) else `AgentBusyError`; keyword notices are queued first, then the user message via `#queueUserMessage` (user-role, `steering:true` flag for steer). Returns.
4. Idle path: eager todo/task preludes, image normalization + text-only-model image-description notice, message role `user` (or hidden `developer` when `options.synthetic`), plan/goal/vibe mode context messages, `#pendingNextTurnMessages` injection, `@file` mention auto-read messages, system prompt rebuild + `before_agent_start` extension event, auto-thinking classification, pre-prompt compaction check, then `agent.prompt(messages)` with a generation counter (`#promptGeneration`) guarding against races with abort/new prompt.
5. In interactive mode, `submitInteractiveInput` (main.ts:277-339) passes `streamingBehavior ?? "followUp"` unconditionally so an Enter racing a background turn queues instead of erroring; the TUI's user Enter carries `"steer"`.

`steer(text, images)` / `followUp(text, images, {synthetic})` (8155-8202): expand templates, normalize images, enqueue on the agent queues, then `#scheduleIdleQueueDrain` — if the agent is idle (not streaming, not retrying) a `continue()` is scheduled so queued messages don't strand. A synthetic followUp becomes a hidden `developer` message.

`abort({reason})` (8781-8851): `reason === "Interrupted by user"` (`USER_INTERRUPT_LABEL`, messages.ts:193) marks a user interrupt; cancels retry, compaction (unless `preserveCompaction`), handoff, bash, eval, post-prompt tasks; `agent.abort`; awaits idle; resets in-flight state; re-records stranded advisor cards; finally drains stranded queued messages (auto-continue).

Queued-input consumption summary (authoritative): steering is consumed (a) at run start, (b) after each tool batch fully settles, (c) at the yield boundary re-poll; follow-ups only at the yield boundary; the mid-batch poll never consumes; external abort never consumes.

Session events (`AgentSessionEvent`, agent-session.ts:499-546): `AgentEvent` ∪ `auto_compaction_start{reason: threshold|overflow|idle|incomplete, action}`, `auto_compaction_end{action,result,aborted,willRetry,errorMessage?,skipped?}`, `auto_retry_start{attempt,maxAttempts,delayMs,errorMessage}`, `auto_retry_end{success,attempt,finalError?}`, `retry_fallback_applied/succeeded`, `ttsr_triggered`, `todo_reminder`, `todo_auto_clear`, `irc_message`, `notice{level,message}`, `thinking_level_changed`, `goal_updated`.

Retry: manual `/retry` (`session.retry()`, no-op while streaming/compacting/retrying); auto-retry of transient provider errors per `retry.*` settings (maxRetries 10, base 500ms, cap 300000ms, model fallback chains per role/`provider/*` wildcards, `fallbackRevertPolicy: cooldown-expiry`); unexpected-stop detection (`features.unexpectedStopDetection`) re-prompts up to `UNEXPECTED_STOP_MAX_RETRIES = 3` with a hidden reminder; `EMPTY_STOP_MAX_RETRIES = 3`, backoff cap `RETRY_BACKOFF_MAX_DELAY_MS = 8000` (agent-session.ts:550-553).

---

## 3. Session persistence (docs/session.md is normative; verified in code)

### 3.1 Locations

- Sessions: `~/.omp/agent/sessions/<dir-encoded>/<timestamp>_<sessionId>.jsonl`. Session id: `Bun.randomUUIDv7()`; timestamp file-safe form replaces `:` and `.` with `-` (session-manager.ts:82-92). `<dir-encoded>` (session-paths.ts:43-59): cwd under `$HOME` → `-<rel>` with `/\\:`→`-` (bare `-` for home itself); under tmp root → `-tmp-<rel>`; else legacy `--<abs-with-dashes>--`. Old home-encoded dirs are migrated once per root, best effort.
- Blob store: `~/.omp/agent/blobs/<sha256>` (content-addressed; refs `blob:sha256:<hash>`).
- Terminal breadcrumbs: `~/.omp/agent/terminal-sessions/<terminal-id>` — two lines: cwd, session-file path; used by `--continue`; breadcrumbs pointing at a subagent artifact file resolve up to the interactive root (`<parent>.jsonl` walk, cap 8).
- Session artifacts dir: `<sessionfile minus .jsonl>/` (subagent JSONLs, tool artifacts, `__advisor.jsonl`).
- Prompt history (separate subsystem): SQLite `~/.omp/agent/history.db`, table `history(id,prompt,created_at,cwd,session_id)` + FTS5 `history_fts`; consecutive-duplicate dedupe; ~100ms batched async inserts.

### 3.2 File format (JSONL, `CURRENT_SESSION_VERSION = 3`)

Physical line 0 (newer files): fixed-width 256-byte **title slot** `{"type":"title","v":1,"title":"…","source":"auto"|"user","updatedAt":"…","pad":"…"}` — mutable in place without rewriting the file. Loaders fold it away. Then the header, then entries:

```json
{"type":"session","version":3,"id":"<uuid7>","timestamp":"2026-…Z","cwd":"/work/pi","title":"…?","titleSource":"auto|user?","parentSession":"<opaque>?","providerPromptCacheKey":"…?"}
```

Every entry has `{ type, id, parentId, timestamp }`; `id` = last 8 chars of a UUIDv4 (collision-checked, Snowflake fallback — session-migrations.ts:5-11); `parentId: null` for roots. Entry union (`session-entries.ts`):
`message{message: AgentMessage}` · `thinking_level_change{thinkingLevel?, configured?}` · `model_change{model:"provider/id", role?}` · `service_tier_change{serviceTier: per-family map|null}` (legacy single strings normalized on read) · `compaction{summary, shortSummary?, firstKeptEntryId, tokensBefore, details?, preserveData?, fromExtension?}` · `branch_summary{fromId ("root" for null), summary, details?, fromExtension?}` · `custom{customType, data?}` (never in LLM context) · `custom_message{customType, content: string|(text|image)[], display, details?, attribution?}` (in LLM context) · `label{targetId, label|undefined-to-clear}` · `title_change{title, previousTitle?, source, trigger?}` (audit) · `ttsr_injection{injectedRules[]}` · `mcp_tool_selection{selectedToolNames[]}` · `session_init{systemPrompt, task, tools[], outputSchema?, spawns?, readSummarize?}` (subagents) · `mode_change{mode, data?}`.

A `message` entry example (doc session.md:127-155) stores the full `AgentMessage` including `usage {input, output, cacheRead, cacheWrite, cost{…,total}}`.

### 3.3 Tree + leaf semantics

Append-only tree with a mutable leaf pointer: every append creates one entry with `parentId = leafId` and becomes the new leaf; `branch(entryId)` only moves the leaf; `resetLeaf()` → next append is a new root; `branchWithSummary()` moves the leaf and appends a `branch_summary`. `getEntries()` = insertion order. `SessionEntryIndex` (session-manager.ts:195-319) maintains byId map, children adjacency, labels, leaf, running usage totals.

### 3.4 Persistence pipeline & guarantees

- Persistence is **deferred until the first assistant message exists**; before that everything is in memory only (avoids junk sessions). Then a full flush, then incremental appends. Appends are written synchronously through a `SessionStorageWriter`; async disk work is serialized through `#diskTail`. `flush()` drains; `flushSync()` does a synchronous full rewrite (used by Ctrl+C). Atomic rewrites = temp write + rename (EPERM move-aside fallback) for `setSessionName`, `rewriteEntries` (pruning), move/fork; migrations set `#rewriteRequired` and rewrite synchronously on next persist. Disk errors latch and rethrow.
- Before persisting: strings truncated to `MAX_PERSIST_CHARS` 500,000 chars with `"[Session persistence truncated large content]"`; transient fields `partialJson`, `jsonlEvents` removed; `lineCount` recomputed; base64 images ≥1024 chars externalized to blob refs; blob refs resolved back on load.
- Loading: `ENOENT` → `[]`; lenient JSONL parse; bad first line → treat as empty and initialize a new session at that path. Migrations: v1→v2 adds id/parentId (linear chain from file order) + `firstKeptEntryIndex`→`firstKeptEntryId`; v2→v3 rewrites `role:"hookMessage"`→`"custom"`.
- Draft-only sessions (only selector metadata entries: `model_change`/`thinking_level_change`/`service_tier_change`/`mode_change`) are marked (`.draft-only-session`) and not resumable as conversations.

### 3.5 Operations

- `SessionManager.create(cwd, sessionDir?)`, `open(path, …, {initialCwd})` (falls back to launch cwd when recorded cwd is gone), `continueRecent`, `forkFrom(src, cwd, …)` (copies history into a *new* file with fresh header; `parentSession = source header id`, inherits `providerPromptCacheKey ?? source id`; carries title), `inMemory()`, `list(cwd)`, `listAll()`.
- `AgentSession.newSession({parentSession?, drop?})` (agent-session.ts:8860): cancellable via `session_before_switch` hook; abort current turn; flush or drop old file; reset provider session ids/caches, memory rekey; appends fresh `thinking_level_change` + `service_tier_change` entries; emits `session_switch`.
- `AgentSession.fork()` (8966): flush, `sessionManager.fork()`, copy the artifacts dir recursively, adopt inherited prompt-cache key.
- `switchSession(path)`, `branch(entryId)` (leaf move + agent-state rebuild), `navigateTree(targetId,{summarize})` (branch-summary flow, §4), `moveTo(newCwd)` (`/move`: re-roots the file into the target cwd's session dir; never chdirs by itself — `/move` handler does `setProjectDir` + settings reload).
- Listing metadata reads a 4KB prefix + bounded 32KB tail per file (`readTextSlices`). `getRecentSessions` default limit 4.
- Derived vs persisted: leaf pointer, index, usage totals, LLM context are derived; entries + header + title slot are the persisted truth. `buildSessionContext(entries, leafId, byId, {transcript})` (§4) resolves what's sent to the model vs the display transcript.

---

## 4. Compaction (docs/compaction.md is normative; `packages/agent/src/compaction/*`)

### 4.1 Triggers (six)

1. Manual `/compact [instructions]` → `AgentSession.compact()` (aborts the active turn first, `preserveCompaction` keeps the manual marker).
2. Overflow recovery: same-model assistant error classified as context overflow, not older than the last compaction. The failing error message is removed; context-promotion (switch to `contextPromotionTarget` model, if `contextPromotion.enabled`) is tried first; else compaction with `reason:"overflow"`, `willRetry:true` (handoff strategy is *not* used here); on success `agent.continue()` retries.
3. Incomplete-output recovery: assistant `stopReason === "length"`; same shape as overflow but handoff *is* allowed; `reason:"incomplete"`.
4. Threshold maintenance: after a successful turn when adjusted context tokens exceed the threshold; `reason:"threshold"`, `willRetry:false`; with `autoContinue !== false`, schedules a developer auto-continue prompt (`prompts/system/auto-continue.md`).
5. Mid-turn maintenance: before the next provider request at safe tool-loop boundaries when `compaction.midTurnEnabled !== false`; handoff suppressed (falls back to context-full); no separate continuation.
6. Idle maintenance: `runIdleCompaction()` (`compaction.idleEnabled`, `idleThresholdTokens` 200000, `idleTimeoutSeconds` 300); `reason:"idle"`; no auto-continue.

### 4.2 Threshold math (compaction.ts:263-342)

`effectiveReserve = max(floor(window*0.15), reserveTokens ?? 16384)`; a *defaulted* reserve that is impossible for a small window falls back to proportional 15%. `resolveThresholdTokens`: `thresholdTokens > 0` → clamp to `[1, window-1]`; else `thresholdPercent > 0` → `floor(window * clamp(pct,1,99)/100)`; else `min(window-1, window - budgetReserve)`. `shouldCompact(contextTokens, window, settings)` = enabled && strategy ≠ off && contextTokens > threshold. Context tokens = provider usage total minus orchestration tokens, floored by a local cl100k estimate of the stored conversation (`compactionContextTokens`) so on-wire compression can't defeat the trigger. Token estimation: cl100k_base via native tokenizer; images charged 1200 tokens.

### 4.3 Pre-passes

- `pruneToolOutputs` (pruning.ts, `DEFAULT_PRUNE_CONFIG`): protect newest 40,000 tool-output tokens; require ≥20,000 total estimated savings; never blank a result under 50 tokens (`MIN_PRUNE_TOKENS`); never prune `skill` results, `skill://` reads, or the active plan-reference read. Pruned content → `[Output truncated - N tokens]`. If anything changed: rewrite session file, refresh agent messages.
- Superseded reads → `[Superseded by a newer read of this file]` (`SUPERSEDED_NOTICE`), useless-flagged results → `[Uneventful result elided]` (`USELESS_NOTICE`); per-turn pass gated by `compaction.dropUseless` (default on); cache-aware timing (only when trailing suffix ≤ ~8k tokens or prompt-cache lifetime elapsed). Blanked in place — pairing preserved, never removed.

### 4.4 Boundary/cut-point (`prepareCompaction`, `findCutPoint`)

Only entries after the previous compaction are considered. Valid cut points: `message` entries with roles `user|assistant|bashExecution|hookMessage|branchSummary|compactionSummary`, `custom_message` entries, `branch_summary` entries. **Never cut at `toolResult`.** Metadata entries directly before the cut are pulled into the kept region. `keepRecentTokens` (default 20000) adapted by measured usage ratio. If the cut is not at a user-turn start (user / bashExecution / custom_message / branch_summary), it's a **split turn**: two summaries (history + turn prefix) merged as:

```
<history summary>

---

**Turn Context (split turn):**

<turn prefix summary>
```

### 4.5 Summary generation

`compact()`: convertToLlm → `serializeConversation()` → wrap in `<conversation>…</conversation>` (+ optional `<previous-summary>`, `<additional-context>` from hooks/memory backend) → one-shot completion with `SUMMARIZATION_SYSTEM_PROMPT`. Prompt files: `compaction-summary.md` (first), `compaction-update-summary.md` (iterative), `compaction-turn-prefix.md` (split second pass), `compaction-short-summary.md` (UI), `handoff-document.md`, `branch-summary.md`, `branch-summary-preamble.md`. Serialization drops useless-flagged tool pairs; tool results truncated head+tail (2000 chars, 0.6 head ratio); tool args capped 500/value, 2000/call.

Remote modes: custom endpoint receives `{systemPrompt, prompt}` returning `{summary}`; an endpoint path ending `/chat/completions` gets standard OpenAI chat body; OpenAI/Codex models first try provider-native `/responses/compact` (preserved in `preserveData.openaiRemoteCompaction`, falls back to local).

File-operation tracking: cumulative read/modified sets from `read`/`write`/`edit` tool calls; rendered as a prefix-folded directory tree with `(Read)/(Write)/(RW)` markers, cap 20 files + `[…N files elided…]`; appended as `<files>` tag; legacy `<read-files>`/`<modified-files>` tags stripped on re-append.

### 4.6 Persist + rebuild

Append `CompactionEntry{firstKeptEntryId, tokensBefore, summary, shortSummary}` → rebuild display context from leaf → replace live agent messages → sync todo phases, close provider sessions with rewritten history → emit `session_compact`. `buildSessionContext`: latest compaction on the path → one `compactionSummary` message, then kept entries from `firstKeptEntryId` up to the boundary, then post-boundary entries. Transcript mode (`{transcript:true}`) instead shows *everything* chronologically with each compaction as an inline divider `── 📷 compacted · ctrl+o ──` (expandable); only the LLM context resets.

### 4.7 Strategies

`compaction.strategy`: `snapcompact` (schema default in settings-schema; `DEFAULT_COMPACTION_SETTINGS` in agent-core uses `context-full`), `context-full`, `handoff`, `shake`, `off`. Snapcompact renders discarded history to model-shape-aware PNG frames (details in docs/compaction.md:133-143 — per-model glyph shapes `11on16-bw`/`8on22-bw`/`8on16-bw`, frame widths 1568/1932/2048px, `maxFrames` 80, requires vision-capable model, else warn + fall back to context-full; manual `/compact` with custom instructions forces LLM summary). Handoff: `generateHandoff()` reuses the live prompt-cache prefix (system prompt + tools + history + one agent-attributed user message, `toolChoice:"none"`); no compaction entry — `AgentSession.handoff()` starts a **new session** and injects the document as a visible `custom_message{customType:"handoff"}`. `/shake` drops heavy content (tool results/large blocks; `elide` default, `images` variant).

### 4.8 Branch summaries

Tied to `/tree` navigation (`branchSummary.enabled`, default false; `branchSummary.reserveTokens` 16384). `navigateTree`: collect abandoned entries old-leaf→common-ancestor; optional summary generation (budget = contextWindow − reserve; newest-first inclusion); `branchWithSummary()` attaches a `branch_summary` at the target. Cancellable via Esc. Hooks: `session_before_compact` (cancel or supply full result), `session.compacting` (prompt/context/preserveData), `session_compact`, `session_before_tree`, `session_tree`.

Failure text: overflow path `Context overflow recovery failed: …`; incomplete `Incomplete response recovery failed: …`; threshold/idle `Auto-compaction failed: …`; dead-end warning pauses auto maintenance ("Compaction freed too little context…").

---

## 5. Settings / config

### 5.1 Files (docs/settings.md)

| Scope | Path | Notes |
|---|---|---|
| Global | `~/.omp/agent/config.yml` | All persistent writes land here (`/settings`, `omp config set/reset`). Debounced saves re-read under a lock. |
| Global legacy | `~/.omp/agent/settings.json` | One-time migration → `config.yml`, renamed `.bak`. |
| Project | `<cwd>/.omp/config.yml` (+ legacy `.omp/settings.json`) | cwd only, **no ancestor walk**; read-only from commands. |
| CLI overlay | `--config <file>` (repeatable) | Later overrides earlier; missing/invalid/non-mapping = hard error. |
| Runtime overrides | in-memory | `--model/--smol/--slow/--plan/--approval-mode/--auto-approve/--yolo/--hide-thinking/--advisor/--no-pty/--api-key`, protocol defaults. |

Precedence (low→high): defaults ← global ← project ← overlays ← runtime. Deep-merge objects; scalars/arrays replaced wholesale. Value parsing for `config set`: booleans accept `true/false/yes/no/on/off/1/0`; numbers finite; enums exact; arrays/records JSON; strings trimmed. `reset` persists the schema default (doesn't delete). `omp config path` prints the agent dir. Env overrides that beat config: `PI_SMOL_MODEL`, `PI_SLOW_MODEL`, `PI_PLAN_MODEL`, `PI_NO_PTY`, `PI_PY`, `PI_JS`, `PI_TINY_DEVICE/DTYPE`, `OMP_AUTH_BROKER_URL/TOKEN`, `PI_CODING_AGENT_DIR`.

### 5.2 Key defaults the port must match (settings-schema.ts / docs/settings.md)

Models: `modelRoles` {} (roles: default, smol, slow, vision, plan, designer, commit, tiny, task, advisor; values allow `:minimal…:max` thinking suffix); `cycleOrder` `["smol","default","slow"]`; `enabledModels` [] (path-scoped entries supported: `path/paths/pathPrefix(es)` + `models/values/items`); `disabledProviders` [] (shared namespace also gating discovery sources `native, claude, codex, gemini, github, opencode, cursor, agents-md`); `includeModelInPrompt` true.
Thinking: `defaultThinkingLevel` high (`auto` allowed); `hideThinkingBlock` false; budgets minimal 1024 / low 2048 / medium 8192 / high 16384 / xhigh 32768 / max 32768.
Sampling: temperature/topP/topK/minP/presencePenalty/repetitionPenalty all `-1` = provider default; `tier.openai|anthropic|google` none, `tier.subagent` inherit, `tier.advisor` none; `personality` default.
Retry: enabled true, maxRetries 10, baseDelayMs 500, maxDelayMs 300000, modelFallback true, fallbackChains {}, fallbackRevertPolicy cooldown-expiry.
Tools: `tools.approvalMode` **yolo** (default), `tools.approval` {}, `tools.discoveryMode` auto, `tools.maxTimeout` 0, `tools.intentTracing` true, `tools.outputMaxColumns` 768, artifact spill threshold 50KB / head 20KB / tail 20KB / tailLines 500.
Shell/eval/LSP: `bash.enabled` true; `bash.autoBackground.enabled` false, threshold 60000ms; `eval.py`/`eval.js` true; `python.kernelMode` session; `lsp.enabled` true, lazy true, diagnosticsOnWrite true, diagnosticsOnEdit false, formatOnWrite false.
Edit/read: `edit.mode` hashline (`apply_patch|hashline|patch|replace`), fuzzyMatch true (0.95), blockAutoGenerated true; `read.defaultLimit` 300, summarize.enabled true.
Compaction: enabled true, strategy snapcompact, midTurnEnabled true, thresholdPercent −1, thresholdTokens −1, reserveTokens 16384, keepRecentTokens 20000, remoteEnabled true, autoContinue true, idleEnabled false, idleThresholdTokens 200000, idleTimeoutSeconds 300; `branchSummary.enabled` false, reserveTokens 16384; `memory.backend` off.
Appearance: `theme.dark` titanium, `theme.light` light; `symbolPreset` unicode; `colorBlindMode` false; `statusLine.preset` default, separator powerline-thin; `terminal.showImages` true; `images.autoResize` true; `tui.hyperlinks` auto.
Interaction: `steeringMode` one-at-a-time (`all` | `one-at-a-time`); `followUpMode` one-at-a-time; `interruptMode` immediate (`immediate|wait`); `doubleEscapeAction` tree (`branch|tree|none`); `autoResume` false; `ask.timeout` 0 s.
Startup: `startup.checkUpdate`, `startup.quiet`, `startup.showSplash`, `startup.setupWizard`, `setupVersion`.

### 5.3 Models config

`~/.omp/agent/models.yml` (`models.json` migrated): `providers.<id>` with `baseUrl`, `api` (`openai-completions`, `openai-responses`, `openai-codex-responses`, `anthropic-messages`, …), `apiKey` (env-var-name-or-literal; `!cmd` runs a shell command and uses stdout), `auth` (`apiKey`(default)/`none`/`oauth`), `authHeader`, `headers`, `models[] {id, name, contextWindow, maxTokens, input, …}`. Registry assembly order: bundled catalog → models.yml → runtime discovery (ollama/llama.cpp/lm-studio keyless) → extension-registered.

### 5.4 Provider auth

Credential resolution order (docs/providers.md): 1 runtime `--api-key` → 2 models.yml key → 3 stored API key → 4 stored OAuth (auto-refresh, multi-account rotation) → 5 provider env var (incl. `.env` files loaded from agent dir/project) → 6 models.yml fallback. Store: SQLite `~/.omp/agent/agent.db` (or auth-broker snapshot; `omp auth-broker login/logout/status/list/import/migrate`). Interactive `/login [provider|redirect-url]`, `/logout`. OAuth providers include Anthropic (`ANTHROPIC_OAUTH_TOKEN` beats API key), GitHub Copilot, OpenAI Codex, Cursor, etc. Env var map printed in `omp --help` (args.ts:302-384): `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `COPILOT_GITHUB_TOKEN`, `AZURE_OPENAI_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`, `KILO_API_KEY`, `MISTRAL_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`, `OPENCODE_API_KEY`, `CURSOR_ACCESS_TOKEN`, `AI_GATEWAY_API_KEY`, AWS/Vertex vars, search keys (`EXA_API_KEY`, `BRAVE_API_KEY`, `TAVILY_API_KEY`, …).

### 5.5 Keybindings + themes config

- `~/.omp/agent/keybindings.yml` (also `.yaml`; legacy `keybindings.json` migrated): flat map of action-id → chord string or array; empty array disables; chords case-insensitive (`Ctrl+P`, `Alt+Shift+P`, `Shift+Enter`, `Ctrl+Backspace`). Old unqualified names migrated to namespaced ids.
- Themes: JSON files validated against `themeJsonSchema` (`src/modes/theme/theme.ts`); required `name` + `colors` (all ~66 tokens listed in docs/theme.md: core text/borders, background blocks, message/tool text, markdown, diff+syntax, thinking-level borders `thinkingOff…thinkingXhigh`, `bashMode`, `pythonMode`, 13 status-line tokens), optional `vars`, `export`, `symbols {preset, overrides}`. Color values: `#RRGGBB`, 0-255 index, var ref, or `""` = terminal default. Dark/light slots selected by terminal background luminance; theme file watcher live-reloads.

---

## 6. Slash commands and interactive keybindings

### 6.1 Built-in slash commands (`src/slash-commands/builtin-registry.ts`, 61 commands)

| Command | Behavior |
|---|---|
| `/settings` | settings panel |
| `/setup` (alias `/providers`) | provider setup; sub `providers` |
| `/plan` | toggle plan mode |
| `/plan-review` | reopen latest plan review |
| `/vibe` | toggle vibe mode |
| `/goal` | goal mode; subs `set/show/pause/resume/drop/budget <N|off>` |
| `/guided-goal` | goal interview |
| `/loop` | loop mode (auto-resubmit prompt after yields) |
| `/queue <msg>` | queue for after yield (same as `->`/`=>` shorthand) |
| `/model` (alias `/models`), `/switch` | model selector |
| `/fast` | priority tier toggle; subs on/off/status |
| `/advisor` | advisor on/off/status/dump/configure |
| `/export [path]` | HTML export |
| `/dump` | transcript → clipboard + request JSON to tmp |
| `/share` | encrypted share link |
| `/collab` (subs view/status/stop), `/join <link>`, `/leave` | live collab relay |
| `/browser` | headless/visible toggle |
| `/copy` | pick text/code to copy |
| `/todo` | subs edit/copy/export/import/append/start/done/drop/rm |
| `/session` | subs info/delete |
| `/jobs` | async background jobs |
| `/usage` | provider usage/limits; sub reset |
| `/stats` | local stats dashboard |
| `/changelog` (sub full) | |
| `/hotkeys` | show live keybindings |
| `/tools` | tools visible to agent |
| `/context` | context usage breakdown |
| `/extensions` (alias `/status`), `/agents` | dashboards |
| `/branch` | branch from a previous message (user-message selector) |
| `/fork` | new fork from a previous message |
| `/tree` | session tree navigation |
| `/login [provider]`, `/logout` | OAuth/key management |
| `/mcp` | subs add/list/remove/test/reauth/unauth/enable/disable/smithery-*/reconnect/reload/resources/prompts/notifications/help |
| `/ssh` | subs add/list/remove/help |
| `/new` | new session |
| `/fresh` | reset provider stream state only |
| `/drop` | delete current session + start new |
| `/compact [instructions]` | manual compaction |
| `/shake` | drop heavy content; subs elide (default), images |
| `/handoff [focus]` | handoff to new session |
| `/resume [id]` | bare → session selector; id → resolve + switch |
| `/btw <question>` | ephemeral side question on current context (b = branch, c = copy keys while active) |
| `/tan <work>` | background tangent agent |
| `/omfg <complaint>` | forge a TTSR rule |
| `/retry` | retry last failed turn (`Nothing to retry` status otherwise) |
| `/debug` | debug tools selector |
| `/memory` | view/stats/diagnose/clear/reset/enqueue/rebuild/mm-* |
| `/rename <title>` | set session title (source "user" wins over auto) |
| `/move [path]` | re-root session to another directory (refuses while streaming) |
| `/exit`, `/quit` | shutdown |
| `/marketplace`, `/plugins`, `/reload-plugins` | plugin management |
| `/force` | force-tool-choice helper |
| `/pause` | process-wide pause gate (parks loop at turn boundaries) |

Also: file-based markdown commands from `commands/` dirs, extension commands, MCP prompt commands, `/skill:<name> [args]` skill invocations (steer on Enter, queued during compaction).

### 6.2 Editor sigils

- `!cmd` = run bash, result shared with model as user message; `!!cmd` = same but `excludeFromContext`. While a bash command runs, `isBashMode` border; Esc aborts it.
- `$ code` / `$$ code` = Python (same kernel as eval backend); `$HOME`-style text without a following space is not a command.
- `-> text` / `=> text` = yield-queue shorthand (`parseQueueShorthand`, modes/queue-input.ts:21) — queue for after the agent yields; enumerated list markers (1., a), roman) are parsed for batch queueing.
- `.` or `c` alone = continue shortcut: hidden synthetic developer "continue" directive, `userInitiated: true` (modes/controllers/input-controller.ts:613-625).
- `@path` mentions auto-read files into context; emoji autocomplete; `#` memory etc. via extensions.

### 6.3 Keybinding actions and defaults (`src/config/keybindings.ts:76-225`)

| Action | Default | Meaning |
|---|---|---|
| `app.interrupt` | `escape` | interrupt ladder (below) |
| `app.clear` | `ctrl+c` | clear editor / double-press quit |
| `app.exit` | `ctrl+d` | shutdown |
| `app.suspend` | `ctrl+z` | suspend (POSIX only) |
| `app.display.reset` | `ctrl+l` | reset terminal display |
| `app.thinking.cycle` | `shift+tab` | cycle thinking level |
| `app.thinking.toggle` | `ctrl+t` | toggle thinking visibility |
| `app.model.cycleForward` / `cycleBackward` | `ctrl+p` / `shift+ctrl+p` | cycle scoped role models |
| `app.model.select` | `alt+m` | model selector (set roles) |
| `app.model.selectTemporary` | `alt+p` | temporary model pick |
| `app.tools.expand` | `ctrl+o` | expand/collapse tool output (also compaction divider) |
| `app.editor.external` | `ctrl+g` | edit draft in `$VISUAL`/`$EDITOR` |
| `app.message.followUp` | `ctrl+q`, `ctrl+enter` | submit as follow-up (queue after turn) |
| `app.retry` | `alt+r` | retry last failed turn |
| `app.message.dequeue` | `alt+up` | pop last queued message back into editor (LIFO) |
| `app.clipboard.pasteImage` | `ctrl+v` (+`alt+v` win32, `super+v` mac) | image-preferred paste |
| `app.clipboard.pasteTextRaw` | `ctrl+shift+v`, `alt+shift+v` | raw text paste |
| `app.clipboard.copyLine` | `alt+shift+l` | copy current line |
| `app.clipboard.copyPrompt` | `alt+shift+c` | copy whole prompt |
| `app.agents.hub` | `alt+a` | agent hub |
| `app.session.observe` | `ctrl+s` | agent hub (observe) |
| `app.session.new` / `tree` / `fork` / `resume` | unbound | |
| session-picker keys: togglePath `ctrl+p`, toggleSort `ctrl+s`, rename `ctrl+r`, delete `ctrl+d`, deleteNoninvasive `ctrl+backspace`; tree fold/unfold `ctrl+left|alt+left` / `ctrl+right|alt+right` | |
| `app.plan.toggle` | `alt+shift+p` | plan mode |
| `app.history.search` | `ctrl+r` | prompt history search |
| `app.stt.toggle` | unbound (hold Space = push-to-talk) | |

### 6.4 Enter semantics by state (input-controller.ts:582-909)

- Idle + text → new turn (submission tagged `streamingBehavior:"steer"` to survive a race with a background turn).
- Streaming + text → `session.prompt(text, {streamingBehavior:"steer"})` — queued steering; editor text/images restored on dispatch error.
- Streaming + **empty** submit with queued messages → `session.abort({reason:"Interrupted by user"})`; queue then drains into a fresh run.
- Compacting → message queued as compaction steer.
- Focused subagent view: editor is a plain chat box; Enter steers the subagent; slash/bash/python refused ("Commands run in the main session — press ←← to return first").
- Ctrl+Q/Ctrl+Enter → follow-up queue instead of steering.

### 6.5 Esc ladder (input-controller.ts:269-389) — evaluated in order

1. Active `/btw` or `/omfg` panel → dismiss.
2. Main view + active maintenance: abort compaction, handoff generation, retry backoff (all advertise "esc to cancel").
3. Loop mode on → pause loop; abort streaming turn or cancel pending submission.
4. Focused subagent → clear typed text, else unfocus back to main (never interrupts the subagent's turn).
5. Collab guest → send abort to host.
6. Loading animation → cancel pending submission, else restore queued messages to editor with abort.
7. Bash running → abort bash; bash mode → clear + exit bash mode; eval running → abort eval; python mode → clear + exit.
8. Streaming → abort the streaming turn (`Interrupted by user`).
9. Non-empty editor → do nothing (protect draft; resets double-esc timer).
10. TTS speaking → silence.
11. Empty + idle: double-Esc within 500ms performs `doubleEscapeAction`: `tree` → tree selector, `branch` → user-message selector, `none` → nothing.

### 6.6 Ctrl+C / Ctrl+D / Ctrl+Z (input-controller.ts:951-1057)

- Ctrl+C: always sync-flush session JSONL first. If shutdown already in flight → `process.exit(130)`. Double-press within 500ms → shutdown; single press → clear editor (records `lastSigintTime`). SIGINT/SIGTERM/SIGHUP route through the same teardown (interactive-mode.ts:823).
- Ctrl+D: shutdown (editor draft snapshotted and persisted as sidecar draft for next resume; empty draft clears stale sidecar).
- Ctrl+Z: win32 → status "not supported". POSIX: stop TUI, `process.kill(0, "SIGSTOP")` (whole foreground process group; SIGSTOP not SIGTSTP because the embedded Rust shell's tokio permanently claims SIGTSTP), `SIGCONT` handler restarts the TUI; failure restores TUI + error.

---

## 7. Approval / permission model (docs/approval-mode.md)

Two inputs: tool-declared tier and user policy.

- Tiers `ToolTier = "read" | "write" | "exec"`; declaration `approval?: ToolApproval` = tier | `{tier, reason?, override?}` | `(args) => decision`. **Omitted = `exec`.** MCP tools declare `write`.
- Modes (`tools.approvalMode`): `always-ask` auto-approves read only; `write` auto-approves read+write; `yolo` (schema default) auto-approves everything. `--auto-approve`/`--yolo` force yolo; `--approval-mode` is a runtime settings override.
- User policy `tools.approval.<toolName>: allow | deny | prompt`, honored in every mode.
- Resolution per call: (1) compute decision from `tool.approval(args)`; (2) normalize user policy (invalid values ignored); (3) yolo: user policy wins if present, else allow — `override` never forces a prompt in yolo; (4) non-yolo + `override:true`: `deny` blocks, everything else prompts (even user `allow`); (5) else valid user policy wins; (6) else mode auto-approves/prompts by tier.
- Safety overrides: bash sets `{tier:"exec", override:true, reason:"Critical pattern detected"}` for destructive patterns (recursive root delete, fork bombs, fetch-then-execute, `/etc/passwd` writes, host shutdown). Reason shows in the prompt.
- Prompt content: `Allow tool: <name>`, `Origin: MCP server tool` for unannotated `mcp__…`, `Reason: <…>`, plus tool `formatApprovalDetails(args)` lines (command, path, code, browser action, subagent assignment).
- ACP: same settings resolver; explicit yolo skips both OMP prompts and the ACP client permission gate for `bash|edit|delete|move` (unless per-tool prompt/deny); default-config ACP still gates through the client. Client-gated calls use ACP `session/request_permission`; generic prompts use form elicitation; rejection/cancel/unsupported ⇒ the tool call is rejected, never silently allowed.
- Subagents run headless with `yolo`; the parent `task` approval is the boundary; per-tool user policies still apply.

---

## 8. Bun/Node-specific machinery the Zig port must replace

- **Runtime**: Bun ≥1.3.14 gate; `bun build --compile` single-binary distribution (`PI_COMPILED` marker; `import.meta.main` quirks). `Bun.semver`, `Bun.randomUUIDv7()` (session ids), `Bun.stdin.text()` (piped prompt), `Bun.file`/`Bun.write` (breadcrumbs etc.), `Bun.env`, `Bun.sleep(0)` yields, `Promise.withResolvers`, markdown prompt files imported via `with { type: "text" }` (embed at build time — Zig `@embedFile`).
- **Workers**: heavy/fragile subsystems run as (a) Worker threads re-entering the same binary with `__omp_worker_*` argv selectors (stats sync, browser tab, JS eval) with message-buffering inboxes to survive Bun's message-flush timing, and (b) IPC **subprocesses** killed with SIGKILL on shutdown for onnxruntime-based workers (tiny title model, STT, TTS, mnemopi embeddings) because the NAPI finalizer would take the process down (cli.ts:103-258). The Zig port can replace with threads/child processes; QuickJS replaces the JS-eval worker.
- **SQLite** (`bun:sqlite`): `agent.db` (auth store + misc), `history.db` (prompt history + FTS5).
- **Rust natives** (`@oh-my-pi/pi-natives`, docs/natives-*.md) — the entire execution/terminal layer is native, not Bun:
  - `shell` — embedded **brush** bash-compatible shell (`executeShell` one-shot, persistent `Shell` sessions; env isolation `do_not_inherit_env`, no profile/rc, native `sleep/timeout/nohup` builtins, session vs command-scoped env, Windows PATH enrichment, `applyBashFixups` strips trailing `| head/tail` and redundant `2>&1`), streaming merged stdout/stderr, `{exitCode?, cancelled, timedOut}`.
  - `PtySession` — PTY-based interactive bash (`PI_NO_PTY=1` / `--no-pty` disables; forced off in rpc-ui); `@xterm/headless` parses PTY output.
  - `Process`/`ps` — cross-platform process refs; `keys` — key parsing; `grep/glob/astGrep/astEdit/fuzzyFind/summarizeCode` — search/code primitives; `countTokens` (cl100k, used by compaction estimates); syntax highlighting; clipboard; SIXEL image encoding; macOS appearance/power assertions; workspace scan; isolation backends (`rcopy/overlayfs/projfs` for task isolation).
- **Signals/process control**: raw-mode TUI consumes Ctrl+C as a key (no SIGINT handler fires); `process.kill(0, "SIGSTOP")` + `SIGCONT` for suspend; postmortem teardown on SIGINT/SIGTERM/SIGHUP/uncaughtException; `process.exit(130)` ladder.
- **node:readline/promises** for the pre-TUI fork/move `[y/N]` prompts; `fetch` with `AbortSignal` timeout for the npm version check and remote compaction; file watching for theme + settings live reload; `EventLoopKeepalive` (interval-based event-loop pinning during prompts).
- **Terminal identity**: `getTerminalId()` (pi-tui) keys the per-TTY breadcrumb files.
- **OpenTelemetry** (optional, `OTEL_EXPORTER_OTLP_ENDPOINT`): GenAI spans `invoke_agent`/`chat`/`execute_tool` — optional for the port.

---

## 9. Misc facts worth pinning

- Thinking levels: `off, minimal, low, medium, high, xhigh, max` + configured sentinel `auto` (resolved per turn by a classifier; per-model Ctrl+P thinking overrides are always concrete) — `src/thinking.ts:128-172`.
- Built-in tool names (`src/tools/builtin-names.ts`): `read, bash, edit, ast_grep, ast_edit, ask, debug, eval, ssh, github, glob, grep, lsp, inspect_image, browser, checkpoint, rewind, task, job, irc, todo, web_search, search_tool_bm25, write, memory_edit, retain, recall, reflect, learn, manage_skill`.
- `AgentTool` extras the loop honors: `hidden`, `loadMode: essential|discoverable`, `concurrency: shared|exclusive|fn`, `lenientArgValidation`, `interruptible`, `intent: omit|optional|require|fn` (intent tracing injects an `i` field into schemas, stripped before execution), `matcherDigest/matcherPaths/matcherEntries` (TTSR stream matching), `approval`, `formatApprovalDetails`.
- System prompt discovery: `SYSTEM.md` / `APPEND_SYSTEM.md` in project `.omp/` (legacy `.pi/`) then global; `TITLE_SYSTEM.md` for title generation (main.ts:750-776).
- Session titles: tiny-model auto-generation on first substantive user message (skipped for low-signal input, `PI_NO_TITLE`, or existing name); stored in the fixed-width title slot; `/rename` writes source "user" which auto-titling never overwrites.
- Home-directory launch protection: starting in `~` without `--allow-home` auto-switches to a temp dir (`applyStartupCwd`).
- `MAX_PAUSED_TURN_CONTINUATIONS = 8`, `MAX_SOFT_TOOL_ESCALATIONS = 3`, steering poll cadence 250ms, `SHUTDOWN_CONSOLIDATE_BUDGET_MS = 1500`, `UNEXPECTED_STOP_MAX_RETRIES = 3` — all hard caps to reproduce.
- Startup watchdog: until a mode runner owns the terminal, print every 10s to stderr `Still starting after Ns — phase: <deepest span>` + log-path hint (main.ts:209-254); paused during interactive prompts.

