# oh-my-pi Extension System & Code-Interpreter Spec (for the QuickJS-NG rebuild)

Upstream root: `/home/autark/src/zig/pi.zig/inspiration` (paths below are relative to it unless absolute).

---

## 1. Extension system

### 1.1 What an extension is

A TS/JS module whose default export (or the module itself, if it is a function) is a factory `(pi: ExtensionAPI) => void | Promise<void>` (`ExtensionFactory`, packages/coding-agent/src/extensibility/extensions/types.ts:1326). One module can combine event handlers, LLM-callable tools, slash commands, keyboard shortcuts, CLI flags, custom renderers, and provider registrations (docs/extensions.md:29-36).

Two-phase lifecycle (docs/extensions.md:40-66):
1. **Load phase** — module imported, factory run. Only *registration* methods are valid. Action methods (`pi.sendMessage()` etc.) throw `ExtensionRuntimeNotInitializedError` (loader.ts:52-56; throwing stubs at loader.ts:62-117).
2. **Runtime phase** — `ExtensionRunner.initialize(actions, contextActions, commandContextActions?, uiContext?)` swaps real implementations into the shared `ExtensionRuntime` object (runner.ts:264-322). After that, events are dispatched and every tool execution is wrapped for interception.

### 1.2 Runtime that executes extensions: **in-process Bun, no sandbox**

- Extensions run in the same Bun process/realm as the agent ("Extensions are **not sandboxed** (same process/runtime). They share one `EventBus` and one `ExtensionRuntime` instance" — docs/extension-loading.md:217-220).
- Import path: `loadLegacyPiModule()` (extensibility/plugins/legacy-pi-compat.ts) — resolves the entry's realpath, dynamically imports with an `?mtime=<tag>` cache-buster so *edited source reloads on same-process re-import* (legacy-pi-compat.ts:473-508, 535-542), and a scoped Bun `onLoad` hook rewrites legacy specifiers (`@mariozechner/*`, `@earendil-works/*`, bare `@sinclair/typebox`) onto host-bundled copies (docs/extension-loading.md:193-200). That `?mtime` rewrite is the whole "hot reload" story — there is no file watcher; reload happens on the next load (e.g. `ctx.reload()` command context action, treated as terminal for the calling command frame, docs/extensions.md:409).
- Failure isolation: per-path load failures collected as `{ path, error }` without aborting other loads (loader.ts:335-359); at runtime handler exceptions are caught and surfaced via `runner.emitError` listeners instead of crashing (runner.ts:601-611).

### 1.3 Discovery (paths, manifest, ordering)

Implemented in `discoverExtensionPaths()` (loader.ts:497-581); order is significant, dedupe is by absolute path, first-seen wins:

1. **Native auto-discovered extension modules** (capability `extension-module`, provider filter `["native"]`, loader.ts:530-537):
   - Project: `<cwd>/.omp/extensions` (cwd-only, no ancestor walk)
   - User: `~/.omp/agent/extensions` (profile-aware: `~/.omp/profiles/<name>/agent/extensions` under `--profile`; honors `PI_CODING_AGENT_DIR`)
   - Legacy settings JSON lists: `<cwd>/.omp/settings.json#extensions`, `~/.omp/agent/settings.json#extensions` (docs/extension-loading.md:29-43)
2. **JS/TS hook factories** from the `hook` capability (e.g. `.omp/hooks/pre/*.ts`) whose entry is `.ts`/`.js` — loaded through the same module pipeline (loader.ts:540-547).
3. **Installed plugin extension entries** via `getAllPluginExtensionPaths(cwd)` — from package `omp.extensions` / legacy `pi.extensions` manifests (loader.ts:549-550).
4. **Explicitly configured paths**: CLI `--extension/-e` (and `--hook` aliases into it), then merged settings `extensions:` array from `~/.omp/agent/config.yml`, `<cwd>/.omp/config.yml`, `<cwd>/.omp/settings.json` (docs/extension-loading.md:60-88).

**Directory entry resolution** (`resolveExtensionEntries`, loader.ts:391-435; `discoverExtensionsInDir`, loader.ts:447-483):
1. `package.json` with `omp.extensions` (or legacy `pi.extensions`) → declared entries, resolved relative to that dir, existing files only;
2. `index.ts`; 3. `index.js`;
4. otherwise a one-level scan: direct `*.ts`/`*.js`, subdir `index.ts|index.js`, subdir `package.json` manifest. No recursion beyond one level; TS preferred over JS in index pairs; symlinks eligible. Native auto-discovery applies gitignore + no-hidden filtering; explicit configured dirs do not (docs/extension-loading.md:158-162).

**Enable/disable**: `--no-extensions` / SDK `disableExtensionDiscovery` (SDK still loads `additionalExtensionPaths`; CLI clears them); `disabledExtensions: [ "extension-module:<derivedName>" ]` where derivedName is `/x/foo.ts → foo`, `/x/bar/index.ts → bar` (docs/extension-loading.md:93-121).

**Separate manifest mechanism**: Gemini-style `gemini-extension.json` under `~/.gemini/extensions/<name>/` and `<cwd>/.gemini/extensions/<name>/` — one-level dir scan, JSON manifest `{ name?, description?, mcpServers?, tools?, context? }`, loose validation, used for MCP-server/context contributions, NOT the TS module path (docs/gemini-manifest-extensions.md).

### 1.4 Full `ExtensionAPI` surface (types.ts:1023-1253)

Module access: `pi.logger`, `pi.typebox` (zod-backed TypeBox shim), `pi.arktype`, `pi.zod` (zod/v4 — canonical for tool params), `pi.pi` (full package exports), `pi.events` (shared `EventBus`).

Registration:
- `on(event, handler)` — full overload list at types.ts:1046-1099 (see §1.6).
- `registerTool(tool: ToolDefinition)` — see §1.7.
- `registerCommand(name, { description?, getArgumentCompletions?, handler(args, ctx: ExtensionCommandContext) })`
- `registerShortcut(keyId, { description?, handler(ctx) })` — reserved keys skipped with warning: `ctrl+c d z k p l o t g q`, `alt+m`, `shift+tab`, `shift+ctrl+p`, `alt+enter`, `escape`, `enter` (runner.ts:404-422).
- `registerFlag(name, { description?, type: "boolean"|"string", default? })` / `getFlag(name)`; flags aggregated last-write-wins (runner.ts:382-390).
- `registerMessageRenderer(customType, renderer)`; `registerAssistantThinkingRenderer(renderer)`.
- `registerProvider(name, ProviderConfig)` — queued into `pendingProviderRegistrations`, processed at session init. `ProviderConfig` = `{ baseUrl?, apiKey?, api?, streamSimple?, headers?, authHeader?, models?: ProviderModelConfig[], oauth?: { name, login, refreshToken?, getApiKey?, modifyModels? }, fetchDynamicModels? }` (types.ts:1260-1323).
- `setLabel(label)`.

Actions (runtime-only):
- `sendMessage(customPayload, { triggerTurn?, deliverAs?: "steer"|"followUp"|"nextTurn" })` — steer interrupts the current run; followUp queues after the run; nextTurn stores hidden context injected on the next user prompt (types.ts:1161-1171; docs/extensions.md:139-145).
- `sendUserMessage(content, { deliverAs?: "steer"|"followUp" })` — always through prompt flow.
- `appendEntry(customType, data?)` — persist non-LLM state into the session JSONL (state rebuild pattern: replay `ctx.sessionManager.getBranch()` on `session_start`/`session_branch`/`session_tree`, docs/extensions.md:351-371).
- `exec(command, args, options?) → Promise<ExecResult>`.
- `getActiveTools() / getAllTools() / setActiveTools(names)`; `getCommands(): SlashCommandInfo[]`.
- `setModel(model) → Promise<boolean>`; `getThinkingLevel() / setThinkingLevel(level)`; `getSessionName() / setSessionName(name)`.

### 1.5 Handler contexts

`ExtensionContext` (types.ts:408-439): `ui` (§1.8), `hasUI`, `cwd`, `sessionManager` (read-only), `modelRegistry`, `model`, `models` (read-only query facade: `list() / current() / resolve(spec) / family(model)` — model-api.ts, types.ts:388-406), `getContextUsage() → { tokens, contextWindow, percent }`, `compact(instructionsOrOptions)`, `isIdle()`, `abort()`, `hasPendingMessages()`, `shutdown()`, `getSystemPrompt(): string[]`, optional `memory: MemoryRuntimeContext`.

`ExtensionCommandContext` extends it (types.ts:449-476) with: `waitForIdle()`, `newSession({parentSession?, setup?})`, `branch(entryId)`, `navigateTree(targetId, {summarize?})`, `switchSession(path)`, `reload()` — all returning `{ cancelled }` where applicable. These are deliberately restricted to user-initiated command handlers.

### 1.6 Event surface (exact names; union `ExtensionEvent` types.ts:888-920)

Session lifecycle: `session_start`, `session_before_switch`→`{cancel?}`, `session_switch`, `session_before_branch`→`{cancel?, skipConversationRestore?}`, `session_branch`, `session_before_compact`→`{cancel?, compaction?}`, `session.compacting` (note the dot), `session_compact`, `session_before_tree`→`{cancel?, summary?}`, `session_tree`, `session_shutdown`.

Prompt/turn: `input` (`{text, images?, source: "interactive"|"rpc"|"extension"}` → `{handled?, text?, images?}`; transforms chain, `handled` short-circuits — runner.ts:868-891), `before_agent_start` (→ `{message?, systemPrompt?}`; system prompt replacements chain), `before_provider_request` (may replace the raw provider payload), `after_provider_response`, `context` (→ `{messages?}`; messages structured-cloned before first handler, runner.ts:893-937), `agent_start`, `agent_end` (notify-only), `session_stop` (→ `{continue?: true, additionalContext} | {decision: "block", reason}`; capped at 8 consecutive continuations, never fires for subagents — docs/extensions.md:222), `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`.

Tools: `tool_call` (pre-exec; result `{block?, reason?}`; **fail-closed** — handler error or 30 s timeout blocks execution, runner.ts:735-787), `tool_result` (middleware-style: handlers run in extension order, each sees prior modifications; may patch `content`/`details`/`isError` — runner.ts:677-718), `tool_execution_start/update/end` (observability), `tool_approval_requested` / `tool_approval_resolved` (emitted by wrapper.ts only when approval is actually required and a handler is subscribed).

Runtime signals: `auto_compaction_start/end`, `auto_retry_start/end`, `ttsr_triggered`, `todo_reminder`, `goal_updated`, `credential_disabled` (buffered pre-initialize, max 32, drained on a microtask after init — runner.ts:127, 338-347).

User command interception: `user_bash` (TUI `!`/`!!` prefix; result `{result?: BashResult}` fully replaces execution), `user_python` (TUI `$`/`$$` prefix; `{result?: PythonResult}`) — types.ts:691-714; emitted from agent-session.ts (~:14455).

`resources_discover` → `{skillPaths?, promptPaths?, themePaths?}` — implemented in the runner (`emitResourcesDiscover`, runner.ts:824-865) but currently has no AgentSession call sites (docs/extensions.md:249-253).

Dispatch rules (runner.ts): every handler raced against a timeout — default `EXTENSION_HANDLER_TIMEOUT_MS = 30_000`, except `session_shutdown` at `SESSION_SHUTDOWN_HANDLER_TIMEOUT_MS = 2_000` and run in parallel (runner.ts:70-97, 622-634). Cancelable `session_before_*` events short-circuit on `{cancel: true}`. Context allocation is deferred until the first matching handler (hot streaming path optimization, runner.ts:614-619).

### 1.7 Tool registration (`ToolDefinition`, types.ts:503-548)

Fields: `name`, `label`, `description`, `parameters` (zod v4 / TypeBox shim / arktype), `hidden?`, `defaultInactive?`, `deferrable?`, `approval?: "read"|"write"|"exec"` (default `"exec"`), `mcpServerName?`, `mcpToolName?`,
`execute(toolCallId, params, signal, onUpdate, ctx: ExtensionContext) → Promise<AgentToolResult>` (result = `{ content: (Text|Image)[], details? }`; `onUpdate` streams partials),
`onSession?(event: { reason: "start"|"switch"|"branch"|"tree"|"shutdown", previousSessionFile }, ctx)`,
`renderCall?(args, opts, theme) → Component`, `renderResult?(result, opts, theme, args?) → Component`.

Wrapping: `RegisteredToolAdapter` adapts to `AgentTool` (wrapper.ts:17-61; render methods only defined when the definition supplies them — otherwise TUI would blank tool output). Every tool (built-in, extension, custom) is additionally wrapped by `ExtensionToolWrapper` (wrapper.ts:82-266) which, in order: (1) applies approval policy (`tools.approvalMode` setting, `tools.approval.<tool>` per-tool policies, CLI `--yolo`; no-UI + approval-required → hard error listing the three remediation options); (2) emits `tool_call` (blockable); (3) executes; (4) emits `tool_result` (patchable; extension may flip error→success or success→error).

### 1.8 UI contributions (`ExtensionUIContext`, types.ts:222-337)

Dialogs: `select(title, options, dialogOptions)`, `confirm`, `input`, `editor(title, prefill?, dialogOptions?, {promptStyle?})`, optional `askDialog(questions[])` (rich multi-question form; result `{kind:"submit", results[]} | {kind:"chat"}`). `ExtensionUIDialogOptions` includes `signal`, `timeout`, `onTimeout/Start/Reset`, `initialIndex`, `outline`, `onLeft/onRight/onExternalEditor`, `helpText`, `selectionMarker: "radio"|"checkbox"`, `checkedIndices`, `markableCount` (types.ts:163-195).

Non-dialog: `notify(msg, "info"|"warning"|"error")`, `onTerminalInput(handler) → unsubscribe`, `setStatus(key, text|undefined)`, `setWorkingMessage(msg?)`, `setWidget(key, string[] | componentFactory | undefined, { placement: "aboveEditor"|"belowEditor" })` (string content capped at 10 lines), `setFooter` / `setHeader` (currently no-op in interactive controller), `setTitle`, `custom(factory, {overlay?})` (focused custom component), `setEditorText` / `pasteToEditor` / `getEditorText`, `addAutocompleteProvider(factory)` (wraps built-in provider, registration order), `setEditorComponent(factory|undefined)` (must return a `CustomEditor` subclass), `theme` getter, `getAllThemes()`, `getTheme(name)`, `setTheme(nameOrTheme)`, `getToolsExpanded()` / `setToolsExpanded(bool)`.

Per-mode support matrix (docs/extensions.md:304-349): interactive = nearly everything; RPC = dialogs round-trip over `extension_ui_request` events, most of the rest no-op; print/headless/subagent = `hasUI=false`, all no-op (`noOpUIContext`, runner.ts:193-220); ACP = only `select`/`confirm`/`input` via elicitations.

### 1.9 Adjacent extensibility surfaces (for the ledger)

- **Hooks** (`src/extensibility/hooks/*`) — legacy event API with a smaller `HookAPI`; today `--hook` is an alias for `--extension` and discovered hook factories load through the extension pipeline (docs/hooks.md:5-16).
- **Custom tools** (`src/extensibility/custom-tools/*`) — tool-only factory modules `(pi: CustomToolAPI) => tool | tool[]`; discovery merges native `.omp/tools`, `~/.claude/tools`, `~/.codex/tools`, plugin manifests; adapted into the same wrappers (docs/custom-tools.md).
- **Real-world example**: packages/swarm-extension (§3.2).

---

## 2. The code-interpreter: the `eval` tool

### 2.1 Tool surface (src/tools/eval.ts)

- Name `eval`, `approval = "exec"`, `concurrency = "exclusive"` (calls never overlap per session), `strict = true`, `loadMode = "essential"` (eval.ts:284-374).
- Params (arktype schema, eval.ts:99-121): `{ language: "py"|"js"|"rb"|"jl", code: string, title?: string, timeout?: number (seconds), reset?: boolean }`. One call = one cell. The wire schema's language enum is narrowed per-session to only enabled backends.
- Backend enablement (src/tools/eval-backends.ts): settings `eval.py`/`eval.js` default **true**, `eval.rb`/`eval.jl` default **false**; env flags `PI_PY`/`PI_JS`/`PI_RB`/`PI_JL` override each key individually.
- Timeout: default 30 s, clamped 1..3600. It is an **inactivity/work budget** enforced by a host-side watchdog (`IdleTimeout`, src/eval/idle-timeout.ts), *paused for the entire duration of host-side bridge calls* (`agent()`, `parallel()`, `completion()`) via reference-counted synthetic status events `EVAL_TIMEOUT_PAUSE_OP`/`EVAL_TIMEOUT_RESUME_OP` (`withBridgeTimeoutPause`, src/eval/bridge-timeout.ts). Cancellation = `AbortSignal.any([callerSignal, watchdogSignal, sessionAbort])`; no fixed wall-clock timer is armed downstream (eval.ts:531-545; docs/python-repl.md:165-182).
- State persists per language across eval calls (persistent kernel/VM); `reset:true` wipes only that language's runtime.
- Output pipeline: streamed chunks go through `OutputSink` (spill threshold `DEFAULT_MAX_BYTES = 50 KiB`, session/streaming-output.ts:11) with optional head-bytes retention and column clamping; full output persisted to an artifact (`artifact://<id>` recoverable), tool result carries truncation metadata via `truncationFromSummary(..., { direction: "tail" })` (eval.ts:513-528, 725-728). Live partials streamed through `onUpdate` with a tail buffer of `2×50 KiB` per cell. `display()` JSON values rendered into result text capped at `MAX_DISPLAY_TEXT_BYTES = 8000` per value with `[…Nch elided…]` (eval.ts:131-144). Images from `display()` are resized and attached as real `ImageContent` so the model can see them; status events (`application/x-omp-status` / `{type:"status"}`) drive a TUI status tree. Renderers: collapsed preview 10 lines (tool) / 20 lines (user-triggered), 4000-char line clamp (docs/python-repl.md:219-229).
- Tool description prompt (src/prompts/tools/eval.md) teaches: one call = one cell = one logical step; state reuse ("NEVER re-import"); the prelude helper table; DAG orchestration via `handle`s; per-language notes ("JS runs under **Bun**: `Bun.file`, `Bun.write`, `Bun.$`, `fetch`, `Buffer`; top-level `await`/`return` work directly").

### 2.2 Prelude / globals exposed to executed code (both runtimes; JS: eval/js/shared/prelude.txt, Python: eval/py/prelude.py)

Common helper set (async in JS, sync in Python):
- `display(value)` — rich output (MIME bundle in py; JSON/image/text classification in JS via `displayValue`, runtime.ts:255-289).
- `print(...)` / full `console` bridge (log/info/warn/error/debug/table/dir/trace/assert/group/time/timeLog/timeEnd/count/countReset — prelude.txt:216-277).
- `read(path, {offset,limit})` — local file read; accepts `scheme://` internal URLs whose root is injected (`local://` → artifacts dir); non-`local://` scheme paths in JS delegate to the host `read` tool with a `:start-end` line selector (prelude.txt:40-64). Confinement mirror: decode, reject absolute/`..`, must stay under the root (helpers.ts:110-144; prelude.py:60-94 via `PI_EVAL_LOCAL_ROOTS` JSON env).
- `write(path, data)` — creates parents, returns resolved path.
- `env(key?, value?)` — get one/set one/list all (JS keeps a Map overlay over `Bun.env`; Python mutates `os.environ`).
- `tool.<name>(args)` — **call any session tool by name** (Proxy in JS → `__omp_call_tool__`; `_ToolProxy` in Python → HTTP bridge). Args get an intent field `i = "js prelude"` / `"py prelude"` injected (tool-bridge.ts:47-56; prelude.py:386-388).
- `output(*ids, format?, query?, offset?, limit?)` — read task/subagent output artifacts (`agent://<id>` via read tool in JS; direct `<artifactsDir>/<id>.md` reads with a mini-jq query language in Python, prelude.py:118-265).
- `completion(prompt, {model:"smol"|"default"|"slow", system?, schema?})` — one-shot stateless completion; `schema` forces a structured tool call named `respond` and returns the parsed object (completion-bridge.ts; tiers map to role patterns `pi/smol`, `pi/default`, `pi/slow`).
- `agent(prompt, {agent?, model?, label?, schema?, isolated?, apply?, merge?, handle?})` — **spawn a subagent** (§2.5).
- `parallel(thunks)` — bounded pool, width = `task.maxConcurrency` (0 = unbounded), barrier semantics, lowest-index error propagates (prelude.txt:140-172; prelude.py:525-567).
- `pipeline(items, ...stages)` — staged waves with a barrier per stage.
- `log(message)` / `phase(title)` — status events for the TUI.
- `budget` — `{total, spent, remaining, hard}` snapshot of the per-turn/Goal-Mode token budget via `__budget__` bridge.

JS-only injected globals (runtime.ts:331-419): `__omp_session__`, `__omp_helpers__`, `__omp_call_tool__`, `__omp_import__`, `__omp_import_from__`, `__omp_get_require__`, `__omp_get_filename__`, `__omp_get_dirname__`, `__omp_emit_status__`, `__omp_log__`, `__omp_table__`, `__omp_display__`, `__omp_set_final_expr__`, `webcrypto`, `require` (dynamic, cwd-aware), `createRequire`, `fs` (real node:fs), plus optional `extraGlobals` (browser worker injects `page`/`browser`). The real `process` is deliberately NOT shadowed; instead `process.stdout/stderr.write` is patched once per process to route into the active run's text sink (runtime.ts:549-577).

### 2.3 JS backend implementation (this is what QuickJS-NG replaces)

Architecture (src/eval/js/*):
- **Host side** (`context-manager.ts`): one `JsSession` per `sessionKey` (the eval session id). Spawns a **Bun `Worker`** (module worker, `argv: ["__omp_worker_js_eval"]` through the CLI entry so compiled builds have one JS entry; fallback to `new URL("./worker-entry.ts")`), with an **inline same-thread fallback** when Worker spawn fails (spawnInlineWorker, context-manager.ts:571-624 — cannot interrupt synchronous loops). Init handshake `init`→`ready` with `WORKER_INIT_TIMEOUT_MS = 15 s` (max'd with the cell timeout); failed worker init retries once on the inline worker. Graceful close: `close` msg → `closed` ack + worker exit within 1 s, else `terminate()`.
- **Wire protocol** (`worker-protocol.ts`): inbound `init{snapshot} | run{runId, code, filename, snapshot} | tool-reply{id, reply} | close`; outbound `ready | init-failed | result{runId, ok, error?} | text{runId, chunk} | display{runId, output} | tool-call{id, runId, name, args} | log | closed`. `snapshot = { cwd, sessionId, localRoots? }`.
- **Worker side** (`worker-core.ts`): owns a `JsRuntime`; per run creates hooks `{onText, onDisplay, callTool}`; tool calls suspend as promises keyed `tc-<runId>-<uuid>` until `tool-reply`. Unhandled-rejection guard attributes floating rejections to the owning cell by scanning stacks for cell filenames (256-entry LRU of finished cell files); an otherwise-successful run **fails with the first floating rejection** (`Unhandled rejection (missing await?): …`), extra ones surface as `[unhandled rejection]` text (worker-core.ts:54-76, 100-182). After the run, one event-loop turn (`Bun.sleep(0)`) is awaited so already-floated rejections fold in.
- **Execution** (`shared/runtime.ts` + `shared/indirect-eval.ts`): user code runs via **indirect `eval` in the worker's global scope** (NOT `node:vm` — Bun crashes on `Worker.terminate()` mid-`vm.runInContext`; indirect-eval.ts:1-23), with `//# sourceURL=js-cell-<uuid>.js` for stack attribution. Per-run hooks resolved through `AsyncLocalStorage` so overlapping async cells route output correctly. Reserved prelude globals are ownership-stacked (`GLOBAL_STACKS`) so multiple runtimes in one realm (inline fallback, browser tabs) can coexist; overlapping cross-runtime runs fail explicitly (runtime.ts:430-532).
- **Code rewriting pipeline** (`shared/rewrite-imports.ts`, `wrapCode`, :531-550), Babel-parsed (lazy-loaded, TS plugin, errorRecovery):
  1. Final-expression capture: last `ExpressionStatement` or top-level `return expr` rewritten to `__omp_set_final_expr__((expr))` so the value surfaces (rewrite-imports.ts:418-446).
  2. TypeScript stripped via `Bun.Transpiler` when a `LOOKS_LIKE_TS` heuristic matches (forced for known `.ts` modules).
  3. Static `import` declarations → `const {…} = await __omp_import__("spec")` (with import-attributes support); dynamic `import(…)` callee swapped for a guard expression that falls back to native import in foreign realms (puppeteer serialization) — rewrite-imports.ts:113-224.
  4. Async-wrapper detection (`await`/`return`/`for await` at top level, execution-boundary aware) → wrap in `(async () => { … })()`.
  5. Cross-cell persistence: top-level `const/let/class` demoted to `var` (indirect eval gives each call its own lexical env; `var` lands on globalThis). When async-wrapped, all top-level bindings (incl. `var`/`function`) are additionally published via `this["name"] = name` (rewrite-imports.ts:344-416).
- **Module loading** (`shared/local-module-loader.ts`): `__omp_import__` resolves against the *active session cwd* with `Bun.resolveSync`. Local path specifiers (`./`, `../`, `/`, `~/`, drive letters) with extensions `.js/.jsx/.mjs/.ts/.tsx/.mts` outside `node_modules` become managed `vm.SourceTextModule` graphs: TS-stripped, `require`/`__filename`/`__dirname` injected per module, `import.meta.url/path/dir` set, link phase serialized via a promise-chain mutex (Bun linker re-entry crashes), **mtime-based invalidation of modules and their dependents on every run** (edit a local module → next cell sees fresh code). Anything else (npm packages, `node:` builtins) goes to native `await import(target)` wrapped in a `SyntheticModule` when imported from a managed module.
- **Cancellation**: abort ⇒ in-flight tool-call controllers aborted, then the worker is **force-terminated** — the only way to interrupt synchronous JS — and the model is told: "The JS worker was force-killed and its VM state was reset; variables from earlier cells are gone." (context-manager.ts:199-207; executor.ts:65-73).
- **Tool bridge host side** (`js/tool-bridge.ts`): `callSessionTool(name, args, {session, signal, emitStatus})` — dispatches reserved names `__completion__`, `__agent__`, `__budget__`, `__concurrency__` to bridge handlers; otherwise resolves via `session.getToolByName(name)` and executes with a synthetic id `js-<name>-<uuid>`. Return shape: plain string when there are no details/images/error, else `{ text, details?, images?: [{mimeType,data}], hasError?: true }`. Per-tool status summaries emitted for `read/write/grep/glob/bash` (op, path/pattern/cmd, counts, 500-char previews).

### 2.4 Python backend (for parity reference)

- One subprocess per `(eval session id, normalized cwd, interpreter)` key: `<python> -u runner.py`, runner script (1322 lines, stdlib-only, no IPython) written once per content-hash to an `omp-python-runner` temp cache (docs/python-repl.md:38-46; py/executor.ts:130-169).
- NDJSON protocol over stdin/stdout: host→ `{id, code, silent?, storeHistory?, cwd?, env?}` / `{type:"exit"}`; runner→ `started | stdout | stderr | display{bundle} | result{bundle} | error{ename,evalue,traceback} | done{status, executionCount, cancelled}` (runner.py:1-27). fd 1 is repointed at a capture pipe so child-process output becomes stdout frames; frames travel on a private dup.
- Init: `os.chdir(cwd)`, env injection, `cwd` on `sys.path`, then the idempotent prelude. Live asyncio event loop → top-level `await` works.
- IPython-style magics rewritten by a line scanner: `%pip %cd %pwd %ls %env %set_env %time %timeit %who %whos %reset %load %run %%bash %%sh %%capture %%timeit %%writefile !cmd var=!cmd var=%magic` (docs/python-repl.md:82-104).
- Tool bridge: **HTTP loopback** — host runs a lazy `Bun.serve` on `127.0.0.1:0` with a bearer token; kernel gets `PI_TOOL_BRIDGE_URL/TOKEN/SESSION`; prelude POSTs `{session, run, name, args}` to `/v1/tool`; registration keyed `sessionId:runId` with fallback to `sessionId`; **responds immediately on cell abort** so blocked urllib worker threads unwind and the kernel survives (py/tool-bridge.ts:33-73). Other env: `PI_EVAL_LOCAL_ROOTS` (JSON scheme→root), `PI_ARTIFACTS_DIR`, `PI_SESSION_FILE`, `MPLBACKEND=Agg` (figures auto-captured to PNG after each cell), `PYTHONUNBUFFERED=1`, `PYTHONIOENCODING=utf-8`.
- Env filtering before spawn: allowlist (PATH, HOME, locale, VIRTUAL_ENV, PYTHONPATH…), allow-prefixes `LC_ XDG_ PI_`, denylist strips provider API keys (docs/python-repl.md:135-140). Interpreter resolution: `python.interpreter` setting > active venv (`VIRTUAL_ENV`, `CONDA_PREFIX`, `<cwd>/.venv`, `<cwd>/venv`) > managed `~/.omp/python-env` > `python`/`python3` on PATH.
- Cancellation: SIGINT → `KeyboardInterrupt` in user code; `SIG_IGN` between requests; if no `done` within 5 s (`INTERRUPT_ESCALATION_MS`), escalate exit→SIGTERM→SIGKILL and recreate the kernel next call. `input()` unsupported. Kernel modes: `python.kernelMode = "session"` (default, retained, dead-kernel replace + one retry) or `"per-call"`.
- Ruby (`eval/rb`) and Julia (`eval/jl`) are analogous opt-in persistent kernels sharing `kernel-base.ts`/`executor-base.ts`.

### 2.5 Can executed code call agent tools / spawn sub-agents? Yes.

- Any session tool: `tool.<name>(args)` (both runtimes) — full registry incl. built-ins, MCP-fronted and extension tools; errors propagate as exceptions.
- Sub-agents: `agent()` → reserved bridge `__agent__` → `runEvalAgent` (eval/agent-bridge.ts:311-592): validates args (arktype), enforces plan-mode block, recursion depth (`EVAL_AGENT_MAX_DEPTH = 3` hard ceiling, `task.maxRecursionDepth` honored below it), spawn policy (`getSessionSpawns`, allowed-agents list), disabled-agents setting, hard turn-budget exhaustion; discovers the agent definition (`task/discovery`), resolves model overrides, allocates an output artifact id, then runs one subagent **subprocess** through `taskExecutor.runSubprocess` — LSP forced off, `maxRuntimeMs` forced 0 (the cell watchdog is paused for the whole bridge call), no shared eval session (would deadlock: parent kernel is blocked on the bridge call). Optional isolation worktree (`isolated:true`, strict opt-in; patch or branch merge-back, `apply:false` keeps artifacts; nested-repo patches persisted for recovery hints). `handle:true` returns a DAG node `{text, output, handle: "agent://<id>", id, agent, data?}` for reference-passing between `pipeline`/`parallel` stages. Progress streamed as `op:"agent"` status events (id, status, lastIntent, currentTool, tokens, cost…).
- `__concurrency__` returns `{limit}` = `task.maxConcurrency` (0 = unbounded); `__budget__` returns `{total, spent, hard}` (per-turn `+Nk`/`+Nk!` directive wins over Goal Mode budget).

### 2.6 User-triggered execution

TUI `!cmd` / `!!cmd` runs bash, `$code` / `$$code` runs Python directly (double prefix = excluded from LLM context); both routed through `user_bash` / `user_python` extension events which may fully replace execution (types.ts:691-714; agent-session.ts:~14442).

---

## 3. The three named packages

### 3.1 `packages/mnemopi` — local SQLite memory engine

Bun/TS port of the "Mnemosyne" memory engine (README). Exposes `Mnemopi` facade (remember/recall/stats/sleep), lower-level `BeamMemory`, MCP tool definitions + dispatcher, optional local ONNX embeddings via `fastembed` (default `BAAI/bge-base-en-v1.5` 768-d, multilingual variant 1024-d) or OpenAI-compatible embedding/LLM endpoints; no bundled GGUF — heuristic fallbacks when no LLM. Large core (vector index, binary vectors, MMR, triple store, episodic graph, temporal parsing, Weibull decay, banks, query cache — src/core/*). Integration in coding-agent: `src/memory-backend/*` (backend interface: `off`, `local`, resolve) + `src/mnemopi/*` (backend.ts, embed worker/client). Enabled with `memory.backend: mnemopi`; scoping `global | per-project | per-project-tagged`; auto-recall into a `<memories>` block on first turn, auto-retain every N turns (`mnemopi.retainEveryNTurns` default 4), pre-compaction context, `/memory view|stats|diagnose|clear|enqueue` commands; ~20 `mnemopi.*` settings (docs/mnemosyne-memory-backend.md). Extensions see it as `ctx.memory: MemoryRuntimeContext` (status/search/save). **Not part of the interpreter story; it's a memory subsystem.**

### 3.2 `packages/swarm-extension` — the canonical real extension

`@oh-my-pi/swarm-extension`, bin `omp-swarm`. Multi-agent DAG orchestration from YAML (`swarm: { name, workspace, mode: pipeline|parallel|sequential, target_count, model, agents: { <name>: { role, task, extra_context?, model?, waits_for?, reports_to? } } }`). Two entries: `src/extension.ts` (TUI extension: `pi.setLabel("Swarm Orchestrator")`; `pi.registerCommand("swarm", …)` with `getArgumentCompletions` for `run|status|help`; uses `ctx.ui.notify`, `ctx.ui.setWidget(key, lines)` live progress widget, `ctx.cwd`, `ctx.modelRegistry`, `pi.pi.settings`, `pi.logger`, and `pi.sendMessage({customType:"swarm-result", content, display:true, details}, {triggerTurn:false})` to inform the LLM) and `src/cli.ts` (standalone, no timeout). `src/swarm/`: schema.ts (YAML parse/validate), dag.ts (dependency graph, cycle detection, topo-sorted waves), executor.ts (**spawns each agent via `runSubprocess` from `@oh-my-pi/pi-coding-agent`** — full-tool subagents), pipeline.ts (iteration/wave loop), state.ts (persists `<workspace>/.swarm_<name>/state/pipeline.json` + logs), render.ts. Agents communicate only through the shared workspace filesystem (signal files/structured outputs/tracking files — README).

### 3.3 `python/` — out-of-process consumers of the RPC mode (not the interpreter)

- `python/omp-rpc`: typed Python client for `omp --mode rpc` newline-delimited JSON RPC over stdio — typed commands/state/events, prompt collection, extension-UI request handling, and `host_tools.py` helpers letting a Python RPC host expose custom tools with JSON-Schema metadata (README).
- `python/robomp`: self-hosted GitHub triage bot. FastAPI + SQLite event queue + worker pool driving `omp --mode rpc` in per-issue git worktrees; classifies issues, fixes bugs on branches, opens PRs; a separate `gh-proxy` container holds the GitHub token and performs all GitHub writes on HMAC-signed requests; host tools are the only GitHub-write surface and every invocation is audited (README).

Neither is the "python eval" implementation — that lives in `packages/coding-agent/src/eval/py/` (§2.4).

---

## 4. QuickJS-NG replacement: required capability list & deviation ledger

The Zig port needs QuickJS-NG for **two distinct roles**: (A) the `eval` tool's JS backend (model-facing interpreter), and (B) the extension host (if TS/JS extensions are kept rather than ported to a native plugin ABI). Requirements below; each maps to upstream behavior cited above.

### 4.1 Must-have runtime capabilities (role A — eval backend)

1. **Persistent global context per eval session** keyed by session id; `reset` destroys and recreates it; state survives across tool calls (eval.ts examples; context-manager sessions map).
2. **Cell execution semantics**: script-mode evaluation in the global scope with (a) final-expression / top-level-`return` value capture (`__omp_set_final_expr__` rewrite), (b) top-level `await` via async-wrapper detection, (c) `const/let/class` → global persistence across cells (var-demotion + `this[...]` publishing when async-wrapped), (d) `//# sourceURL`-style cell filenames for stack attribution. QuickJS can evaluate as module (native TLA) — but then binding-persistence and final-expression rules must be re-implemented to match.
3. **A JS parser/rewriter** equivalent to the Babel pipeline: static-import → host-import-call rewriting, dynamic-import callee swap, final-expression rewrite, top-level lexical scan, async-wrapper detection. (Zig-side: either embed a JS-based transformer run inside QuickJS itself, or port the transforms.)
4. **Event-loop pumping**: microtask draining (`JS_ExecutePendingJob`), plus a host-driven macro loop for timers and pending host promises; the "one turn after run to fold floating rejections" behavior needs an explicit hook. **Unhandled-rejection tracking** (QuickJS-NG has a host callback) attributing rejections to cells and failing an otherwise-ok run.
5. **Host function bindings** for the full injected-global set (§2.2/2.3): `__omp_call_tool__` (async, promise-returning), `__omp_import__`/`__omp_import_from__`, `__omp_emit_status__`, `__omp_log__`, `__omp_table__`, `__omp_display__`, `__omp_set_final_expr__`, helper bag `read/write/env`, and the prelude (which is plain JS and can be executed nearly verbatim — prelude.txt has no Bun dependencies except via helpers).
6. **Tool-call bridge**: async suspension of cell code on `tool.<name>()` with request/reply correlation, abort propagation, and the reserved bridge names `__completion__`, `__agent__`, `__budget__`, `__concurrency__` handled host-side (in Zig, against ai.zig's tool loop / subagent executor). Intent-field injection (`i: "js prelude"`).
7. **stdout/stderr routing & display protocol**: `onText` chunks, `onDisplay` outputs of `{type:"json"|"image"|"status"|"markdown"}` with strict-base64 image coercion rules (runtime.ts:55-139), status-event upsert semantics, and the 50 KiB tail/artifact-spill truncation contract.
8. **Cancellation**: interrupt handler (`JS_SetInterruptHandler`) to stop synchronous loops — this is *better* than upstream (Bun must kill the whole worker and lose state); decide whether to preserve state on interrupt (deviation, arguably an improvement — document either way). Timeout = inactivity watchdog with bridge-pause semantics, not a wall clock.
9. **Module loading**: resolve specifiers against the *session cwd*; local `.js/.mjs`(/ported `.ts`?) files as real modules with mtime-based invalidation of the module and its dependents; cyclic-graph support. npm `node_modules` resolution is where Bun does heavy lifting (see ledger).
10. **fs access**: the helpers need real filesystem read/write plus the internal-URL (`local://`) root map with decode/traversal/containment checks; these are host functions, easy in Zig.
11. **Timers**: `setTimeout/clearTimeout/setInterval` are not in the prelude but user code and console-timers rely on `Date.now` only; still, model-written code will call `setTimeout` — provide host timers integrated with std.Io.
12. **fetch**: upstream exposes Bun's global `fetch` (advertised in the tool prompt). A QuickJS build must bind an HTTP client (ai.zig's) as `fetch` (Request/Response subset) or ledger it out.
13. **Concurrency/pooling**: `parallel`/`pipeline`/`__pool` are pure prelude JS over promises; they only need working promises + the `__concurrency__` bridge.
14. **Python parity note**: the Python/Ruby/Julia backends are *subprocess kernels speaking NDJSON* — they port to Zig unchanged in architecture (spawn `python -u runner.py`, keep runner.py/prelude.py byte-for-byte) and do not involve QuickJS at all. The loopback HTTP tool bridge (`/v1/tool`, bearer token, session:run keying, respond-on-abort) must be reimplemented on std.Io.

### 4.2 Must-have capabilities (role B — extension host), if JS extensions are kept

- Module loading from the discovery paths in §1.3 with the manifest rules; factory invocation with a registration-only API object; per-path error isolation.
- Full `ExtensionAPI`/`ExtensionContext` binding surface (§1.4-1.5) as host functions; the event dispatch engine with per-handler 30 s / 2 s(session_shutdown) timeout races, fail-closed `tool_call`, middleware `tool_result`, chaining `input`/`context`/`before_provider_request`.
- zod-shaped schema authoring is impractical to bind natively — the port should accept JSON-Schema (or a small schema DSL) for `parameters` and ledger `pi.zod`/`pi.typebox`/`pi.arktype` as deviations.
- UI context bridging to ZigZag components (dialogs, widgets, status, editor text). `renderCall`/`renderResult`/`registerMessageRenderer` return **pi-tui Component objects** — a QuickJS extension cannot construct Zig TUI components directly; the port needs a declarative render contract (e.g. return styled-text arrays) — ledger as an intentional API change.

### 4.3 Bun-only luxuries → deviation ledger (recommend: document, don't rebuild)

| Upstream capability | Where | Suggested disposition |
|---|---|---|
| TypeScript execution everywhere (extensions in TS, eval cells transpiled via `Bun.Transpiler`, TS local modules) | rewrite-imports.ts:504-529; loader.ts | Ledger: JS-only extensions/cells in v1, or embed a JS transpiler (e.g. sucrase) inside QuickJS |
| Full npm `node_modules` resolution + native `import` of arbitrary packages (`Bun.resolveSync`, synthetic modules) | local-module-loader.ts:230-330 | Ledger: no npm packages in eval cells; local-file modules + a curated builtin set only |
| Bun globals advertised to the model: `Bun.file`, `Bun.write`, `Bun.$`, `Buffer`, `fetch` | prompts/tools/eval.md | Replace with host bindings (`read`/`write` helpers, `fetch` shim, `tool.bash`); rewrite the tool prompt accordingly |
| Real `node:fs`, `require`, `createRequire`, real `process` object exposed to cells | runtime.ts:393-399 | Ledger: provide minimal `fs`-like host object + `env()`; no `require` |
| Worker-thread isolation with force-`terminate()` for stuck sync code (+ inline fallback, SIGTRAP/vm.runInContext workarounds) | context-manager.ts, indirect-eval.ts | Superseded: QuickJS interrupt handler interrupts sync loops in-process; the whole worker/transport/inline-fallback layer collapses |
| Babel parser (lazy) for rewrites | rewrite-imports.ts:79-105 | Port the ~6 transforms over a Zig or embedded-JS parser |
| `AsyncLocalStorage` per-run hook routing (overlapping cells in one realm) | runtime.ts:169, 22-34 | Simplify: eval tool is `concurrency:"exclusive"`; one active run per context is acceptable |
| Bun `onLoad` specifier shim for legacy `@mariozechner/*` packages, `?mtime` cache-busting reload | legacy-pi-compat.ts | Ledger: no legacy-pi compat; reload = rebuild the QuickJS context |
| `Bun.serve` loopback tool bridge for Python | py/tool-bridge.ts | Reimplement small HTTP server in Zig (required, not a luxury) |
| Puppeteer/browser tab worker sharing `JsRuntime` (`extraGlobals: page/browser`), global ownership stacks | runtime.ts:36-50, 430-532 | Ledger: out of scope; drop ownership-stack machinery |
| `structuredClone` for `context` event message copies and display JSON | runner.ts:908, runtime.ts:279 | Use JSON round-trip with documented non-cloneable fallback |
| Ruby/Julia kernels (opt-in) | eval/rb, eval/jl | Ledger: py + js only in v1 (upstream defaults match: rb/jl off) |
| OAuth `registerProvider.oauth` login flows from extensions | types.ts:1276-1287 | Ledger unless ai.zig grows a pluggable OAuth surface |
| `registerAssistantThinkingRenderer`, custom editor components, autocomplete-provider stacking | types.ts:307-318, 1155 | Ledger: declarative subset only |

### 4.4 Contract details worth preserving exactly

- Event names (incl. the odd `session.compacting` dot), result shapes, and cancel/short-circuit semantics (§1.6).
- `deliverAs` message semantics (`steer`/`followUp`/`nextTurn` + `triggerTurn`).
- Tool bridge value shape: bare string vs `{text, details, images, hasError}` (js/tool-bridge.ts:19-28,139-155) — the prelude helpers depend on it.
- `agent()` node dict keys: `{text, output, handle, id, agent, data?, isolated?, patchPath/patch_path?, branchName/branch_name?, nestedPatches?, changesApplied?, isolationSummary?}` (camelCase in JS, snake_case in Python).
- Depth ceiling 3, spawn policy, budget gate, and the "own eval session per bridge-spawned subagent" rule (deadlock avoidance, agent-bridge.ts:439-444).
- Timeout defaults: cell 30 s (1..3600), extension handler 30 s, shutdown handler 2 s, worker init 15 s, interrupt escalation 5 s, output tail 50 KiB, display JSON 8000 chars, ask-widget 10 lines.

