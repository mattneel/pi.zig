# Pi (oh-my-pi) AI/Agent Layer → ai.zig Mapping Report

Scope: upstream at `/home/autark/src/zig/pi.zig/inspiration` (packages `agent`, `ai`, `catalog`, `wire`, plus `coding-agent` where it hosts the approval policy and session serialization); target library at `/home/autark/src/zig/ai.zig`. All paths below are relative to those roots unless absolute.

---

# PART 1 — Upstream: oh-my-pi's AI/agent layer

## 1.1 Package map

| Package | npm name | Role |
|---|---|---|
| `packages/agent` | `@oh-my-pi/pi-agent-core` | Agent loop (`agent-loop.ts`, 2373 LOC), `Agent` class (`agent.ts`, 1386 LOC), compaction (`compaction/`, 5122 LOC), append-only context, pause gate, run collector, OTel telemetry, tokenizer |
| `packages/ai` | `@oh-my-pi/pi-ai` | `streamSimple`/`completeSimple`, 14 provider transports + registry, auth storage (OAuth, SQLite), auth broker/gateway, error taxonomy, usage-limit reporting, in-band tool-call dialects, schema utils |
| `packages/catalog` | `@oh-my-pi/pi-catalog` | `Model` metadata (cost, context window, thinking config, compat matrix), `Effort` enum, bundled `models.json` (~12K models), runtime model manager + on-disk cache, provider discovery |
| `packages/wire` | `@oh-my-pi/pi-wire` | Dependency-free JSON mirror of message/event shapes for the collab web client; also exports `INTENT_FIELD = "i"` (`wire/src/index.ts:400`) |

## 1.2 Message model (exact shapes, `packages/ai/src/types.ts`)

`Message = UserMessage | DeveloperMessage | AssistantMessage | ToolResultMessage` (types.ts:785).

- **`UserMessage`** (676–688): `role:"user"`, `content: string | (TextContent|ImageContent)[]`, `synthetic?: boolean`, `steering?: boolean` (set when injected mid-turn as a steer; the pre-LLM transform wraps it for emphasis; never rendered), `attribution?: "user"|"agent"`, `providerPayload?` (opaque transport-native history, currently `OpenAIResponsesHistoryPayload`), `timestamp: number` (epoch ms).
- **`DeveloperMessage`** (690–698): `role:"developer"`, same content/attribution/payload/timestamp.
- **`AssistantMessage`** (723–763): `role:"assistant"`, `content: (TextContent|ThinkingContent|RedactedThinkingContent|AnthropicFallbackContent|ToolCall)[]`, `api: Api`, `provider: Provider`, `model: string`, `contextSnapshot?: {promptTokens, nonMessageTokens, lastMessageTimestamp?}` (717–721), `retryRecovery?`, `responseId?`, `upstreamProvider?` (aggregator-reported), `usage: Usage`, `stopReason: StopReason`, `stopDetails?`, `errorMessage?`, `toolCallAbortMessages?: Record<string,string>`, `errorStatus?` (HTTP), `errorId?` (bit-classified), `disabledFeatures?: string[]` (features the server silently dropped, e.g. `"priority"`), `providerPayload?`, `timestamp`, `duration?`, `ttft?` (ms).
- **`ToolResultMessage`** (765–783): `role:"toolResult"`, `toolCallId`, `toolName`, `content:(TextContent|ImageContent)[]`, `details?: TDetails` (UI/log payload, not sent to model), `isError: boolean`, `attribution?`, `prunedAt?` (ms; set when output was pruned), `useless?` (compaction may elide once consumed; never with isError), `timestamp`.

Content blocks: `TextContent {type:"text", text, textSignature?}` (598), `ThinkingContent {type:"thinking", thinking, thinkingSignature?, itemId?}` (604), `RedactedThinkingContent {type:"redactedThinking", data}` (611), `AnthropicFallbackContent {type:"fallback", from:{model}, to:{model}}` (624; stripped on cross-provider replay), `ImageContent {type:"image", data(base64), mimeType, detail?: "auto"|"low"|"high"|"original"}` (630), `ToolCall {type:"toolCall", id, name, arguments:Record<string,unknown>, [kStreamingPartialJson]?, thoughtSignature?(Google), intent?, rawBlock?(in-band dialects), customWireName?(OpenAI custom-tool wire name)}` (642).

`StopReason = "stop"|"length"|"toolUse"|"error"|"aborted"` (665).

**`AgentMessage`** (`packages/agent/src/types.ts:544`) = `Message | CustomAgentMessages[keyof CustomAgentMessages]` — apps extend by declaration merging (e.g. UI-only artifact/notification messages). `convertToLlm` filters/lowers `AgentMessage[]` → `Message[]` per LLM call; default keeps user/toolResult/assistant, dropping provider-refusal assistants (`agent.ts:60-65`).

## 1.3 Provider streaming event union (the "assistant message event")

`AssistantMessageEvent` (`ai/types.ts:904-926`) — every provider emits exactly this union; every event except the terminal two carries `partial: AssistantMessage` (the in-progress accumulated message):

```
{type:"start", partial}
{type:"text_start"|"text_delta"(delta)|"text_end"(content), contentIndex, partial}
{type:"thinking_start"|"thinking_delta"(delta)|"thinking_end"(content), contentIndex, partial}
{type:"toolcall_start"|"toolcall_delta"(delta)|"toolcall_end"(toolCall), contentIndex, partial}
{type:"done", reason: "stop"|"length"|"toolUse", message: AssistantMessage}
{type:"error", reason: "aborted"|"error", error: AssistantMessage}   // error is ALSO an AssistantMessage
```

Streams are `EventStream<AssistantMessageEvent, AssistantMessage>` (`ai/src/utils/event-stream.ts:5`): push-based queue + `result()` promise resolved by the terminal event; `fail(err)` for machinery errors; `pendingLocalWork` counter suppresses idle watchdogs while local tool bridging is in flight.

Key invariant: **provider errors are data** — the terminal `error` event carries a fully-formed `AssistantMessage` with `stopReason:"error"|"aborted"`, `errorMessage`, `errorStatus`, `errorId`, zeroed usage, so the loop and session always persist a message rather than throwing.

## 1.4 Agent loop

Entry points (`agent/src/agent-loop.ts`):
- `agentLoop(prompts: AgentMessage[], context: AgentContext, config: AgentLoopConfig, signal?, streamFn?) → EventStream<AgentEvent, AgentMessage[]>` (333).
- `agentLoopContinue(context, config, signal?, streamFn?)` (374) — resume without a new prompt; asserts last message is not `assistant`.
- `agentLoopDetailed`/`agentLoopContinueDetailed` (474/493) — same stream + `detailed()` promise adding `AgentRunSummary`/`AgentRunCoverage`.

`AgentContext = {systemPrompt: string[], messages: AgentMessage[], tools?: AgentTool[]}` (types.ts:710).

### AgentEvent union (exact, `agent/src/types.ts:720-741`)

```
{type:"agent_start"}
{type:"agent_end", messages: AgentMessage[], telemetry?: AgentRunSummary, coverage?: AgentRunCoverage}
{type:"turn_start"}
{type:"turn_end", message: AgentMessage, toolResults: ToolResultMessage[]}
{type:"message_start", message}
{type:"message_update", message, assistantMessageEvent: AssistantMessageEvent}   // assistant streaming only
{type:"message_end", message}
{type:"tool_execution_start", toolCallId, toolName, args, intent?}
{type:"tool_execution_update", toolCallId, toolName, args, partialResult}
{type:"tool_execution_end", toolCallId, toolName, result, isError?}
```

`message_update` deep-clones (snapshots) the partial each delta so subscribers get immutable views (`agent-loop.ts:182-243`).

### Loop control flow (runLoopBody, agent-loop.ts:755-1186)

Outer loop (follow-up drain) wrapping an inner loop (turns). Per inner iteration:
1. Deadline check (`config.deadline` = **absolute epoch ms**; a timer aborts an internal controller merged into `signal`, 766–778).
2. `yieldIfDue()` event-loop yield; park on the **process-global pause gate** (`pause.ts` `agentPauseGate`; freezes all loops at turn boundaries/pre-tool without aborting; a run's own abort releases only its park).
3. Inject `pendingMessages` (steering/asides/follow-ups) as message_start/message_end + context append.
4. `syncContextBeforeModelCall(context)` — refresh systemPrompt/tools from live state.
5. Resolve tool-choice directive **once per logical turn** (getToolChoice is a consuming generator upstream): hard `ToolChoice` applied verbatim, or `SoftToolRequirement {soft:true, id, toolName, reminder: AgentMessage[]}` (types.ts:59-73) — inject `reminder` once per new id, keep tool_choice auto; if the model then calls anything other than only the required tool, pair every detour call with a skipped result and **force** `{type:"tool", name}` for exactly one turn (max `MAX_SOFT_TOOL_ESCALATIONS = 3`, then throw). Rationale: changing tool_choice invalidates the provider message cache.
6. `streamAssistantResponse(...)` (1209): re-resolves per call `getModel()`, `getReasoning()`, `getDisableReasoning()`, `getServiceTier(model)` (authoritative), `getCwd()`, `getApiKey(model)` (then `metadataResolver(provider)` so metadata reflects the chosen credential); applies `transformContext` (AgentMessage level) → `convertToLlm` → `normalizeMessagesForProvider` (strips thinking blocks for cerebras, 541–569) → `normalizeTools` (intent-field injection, examples rendering, description pruning, 633–663) or `appendOnlyContext.build()` → `transformProviderContext` → optional owned dialect wrap (`renderInbandToolPrompt` + `encodeInbandToolHistory`, tools:undefined) → `streamFn || streamSimple`. Consumes the event stream with a single registered abort race; pushes message_start/update/end; on `done`/`error` runs `transformAssistantMessage(finalMessage)` (in-place mutation seen by transcript/UI/tools alike); Harmony-leak detection can abort-retry (≤2, temperature +0.05) or truncate-and-resume (≤2 across the run).
7. Stop handling:
   - `stopReason error|aborted`: synthesize **placeholder tool results** for every tool call in the message (keeps tool_use/tool_result pairing) tagged `SyntheticToolResultDetails {__synthetic:true, source, executed:false, upstreamError?}` (2258), emit turn_end + agent_end, return.
   - Tools run when `(stopReason=="toolUse" || stopReason=="stop") && toolCalls.length>0` (988–1012) — `stop` with tool calls still runs them (Anthropic adaptive thinking emits calls under end_turn). `length` never runs tools: pair each with a placeholder explaining truncation and loop again (1080–1098).
   - Non-terminal stop `stopDetails.type=="pause_turn"` with no tool calls: re-sample, capped at `MAX_PAUSED_TURN_CONTINUATIONS = 8` (89).
   - A tool hook can abort with `TERMINAL_TOOL_RESULT_ABORT_REASON` (Symbol, 143) to stop after persisting a completed batch (subagent yield).
8. `emitTurnEnd` (437): push turn_end; run `onTurnEnd(messages, signal, {message, toolResults, willContinue})` unless aborted/errored.
9. Boundary polls: dequeue steering via `getSteeringMessages()`; if continuing, also fold non-interrupting **asides** (`getAsideMessages()` — entries are messages or sync thunks returning message|null, resolved at injection time, 745). At the stop boundary: `onBeforeYield()`, re-poll steering + asides + `getFollowUpMessages()`; anything queued sets pendingMessages and continues the outer loop; otherwise `agent_end`.
   On external abort every dequeue is skipped so queued steering survives into a post-abort continue (1132-1138).

### Tool execution (executeToolCalls, 1766-2239)

- Batch = tool calls of one assistant message; `ToolCallContext {batchId, index, total, toolCalls:[{id,name}]}` given to `getToolContext`.
- **Concurrency scheduling**: per-tool `concurrency: "shared"|"exclusive"|fn(rawArgs)`; shared tools run concurrently, an exclusive tool waits for everything before it and blocks everything after (2174-2202).
- Per-record signal: interruptible tools observe steering + external + IRC aborts; others only steering + external (1804-1809) — so a peer interrupt never kills a foreground side-effecting tool mid-run.
- `checkSteering` after each tool completes (+ a 250 ms poll `STEERING_INTERRUPT_POLL_MS` while any interruptible tool runs): non-consuming `hasSteeringMessages()` (bool or `{queued, source: "user"|"system"|"unknown"}`) and `hasIrcInterrupts()`; a hit aborts the batch controller → remaining tools are paired with skipped results ("Skipped due to queued user message… retry the skipped tool if it is still needed", 2351-2373). Disabled when `interruptMode:"wait"` (default `"immediate"`).
- Per-call pipeline: intent extraction (strip `i` field; or derive via `tool.intent(fn)`) → `validateToolArguments` (schema; `lenientArgValidation` passes raw args through on failure) → `beforeToolCall(ctx, signal)` (may `{block:true, reason}` → error result; may mutate `args` in place — no re-validation) → `transformToolCallArguments` → `tool.execute(toolCallId, params, signal, onUpdate, toolContext)` streaming partials via `tool_execution_update` → `coerceToolResult` (normalizes malformed third-party results; empty error content becomes "Tool failed with no output.", 254-327) → `afterToolCall(ctx, signal)` (field-by-field override of content/details/isError/useless, re-coerced) → emit `tool_execution_end` + a `ToolResultMessage`.
- Thrown tool errors become error results; they never abort the batch.

### Agent class (`agent/src/agent.ts:328`)

Owns `AgentState` (549): `{systemPrompt: string[], model: Model, thinkingLevel?: Effort, disableReasoning?, tools: AgentTool[], messages: AgentMessage[], isStreaming, streamMessage, pendingToolCalls: Set<string>, error?}`. Default model `getBundledModel("google","gemini-2.5-flash-lite-preview-06-17")` (331).

- Queues: `steer(m)` / `followUp(m)`; modes `steeringMode`/`followUpMode`: `"all" | "one-at-a-time"` (default one-at-a-time, 428-429); `popLastSteer/popLastFollowUp` (LIFO dequeue for keybinding); `peekSteeringQueue/peekFollowUpQueue` non-consuming views; `clear*Queues`.
- `prompt(text|msg|msgs, images?, {toolChoice?})` — throws `AgentBusyError` if streaming; `continue()` — resumes; if last message is assistant, drains one steering (with `skipInitialSteeringPoll`) or follow-up batch instead.
- `abort(reason?)`, `waitForIdle()`, `reset()`, `replaceMessages(ms)` (defensive `.slice()`), `appendMessage`, `popMessage`.
- Wires `AgentLoopConfig` per run (1119-1205): `getSteeringMessages` = dequeue by mode; `hasSteeringMessages` classifies queue source (user vs system by role+attribution, 1187-1199); `getToolChoice` drops directives whose tool is no longer registered (73-89, 1108-1117); `getModel/getReasoning/getDisableReasoning` read live state so mid-run `/model`, thinking-level changes apply on the next call; `syncContextBeforeModelCall` re-reads systemPrompt/tools.
- Message-history ownership: state messages are plain JSON objects; the loop deep-snapshots assistant messages (`snapshotAssistantMessage`, structuredClone of tool args/usage) before appending/emitting, so listeners can retain events safely. Loop context takes `messages.slice()` and the Agent re-appends via `message_end` events.
- Error path (1279-1326): any thrown loop error becomes a synthesized assistant message (`stopReason: aborted|error`) appended to history + `agent_end`.

## 1.5 Provider selection, streaming interface, transports

- **`streamSimple(model, context, options?: SimpleStreamOptions) → AssistantMessageEventStream`** (`ai/src/stream.ts:1000`); `completeSimple` (1215) adds thinking-loop re-sampling (≤3 aborts then "let it cook" with guard disabled, 904-943). `Context = {systemPrompt?: string[], messages: Message[], tools?: Tool[]}` (types.ts:898).
- Dispatch order inside streamSimple: proxy/debug/extra-CA fetch wrapping → **ApiKeyResolver driver** (see 1.10) → `transport:"pi-native"` short-circuit (gateway proxies to `POST /v1/pi/stream`) → custom API registry (`api-registry.ts`: `registerCustomApi(api, streamSimple, sourceId?)`, built-in names reserved) → vertex/bedrock ambient-credential paths → env API key fallback (`getEnvApiKey`) → special routers (gitlab-duo, kimi `format: openai|anthropic` default anthropic, synthetic default openai) → `mapOptionsForApi` → per-API `stream*` function.
- **`KnownApi`** (catalog/types.ts:8-23): `openai-completions, openai-responses, openrouter, openai-codex-responses, azure-openai-responses, anthropic-messages, bedrock-converse-stream, google-generative-ai, google-gemini-cli, google-vertex, ollama-chat, cursor-agent, gitlab-duo-agent, devin-agent`. `Api = KnownApi | string` (extension APIs).
- `StreamFn` (agent/types.ts:28) — the whole loop is parameterized over the stream function; `packages/agent/src/proxy.ts` implements a server-relayed variant with a bandwidth-reduced event vocabulary (partials stripped; client reconstructs and re-runs `calculateCost`).
- Heavy provider modules are lazily imported (stream.ts:39-59). Leaked-thinking healing wraps every non-official endpoint (105-144); Gemini gets a thinking-loop guard.
- **Per-provider in-flight caps**: `maxInFlightRequests: Record<provider, number>` enforced **cross-process** via lease directories under `<config>/run/provider-inflight` with heartbeats (10s/30s/5s constants, stream.ts:160-320).
- **`SimpleStreamOptions`** (types.ts:519-583) extends `StreamOptions` (350-516). Full field inventory: sampling (`temperature,topP,topK,minP,presencePenalty,repetitionPenalty,frequencyPenalty,stopSequences,maxTokens`), `signal`, `apiKey: string|ApiKeyResolver`, `cacheRetention: "none"|"short"|"long"`, `headers`, `initiatorOverride: "user"|"agent"`, `maxRetryDelayMs` (default 60000; 0 disables cap), `metadata`, `loopGuard {enabled?, checkAssistantContent?}`, `taskBudget {type:"tokens", total, remaining?}` (Anthropic `output_config.task_budget`), `sessionId`, `promptCacheKey` (OpenAI-family `prompt_cache_key` / `x-grok-conv-id`; falls back to sessionId), `providerSessionState: Map<string, ProviderSessionState{close()}>` (session-scoped transport reuse, e.g. Codex WebSocket), `codexCompaction`, Gemini Interactions fields (`useInteractionsApi, storeInteraction, previousInteractionId`), `maxInFlightRequests`, observers (`onPayload` — may replace payload; `onResponse(ProviderResponseMetadata)`; `onSseEvent(RawSseEvent)` incl. synthetic frames for the Codex WebSocket transport), stream watchdogs (`streamFirstEventTimeoutMs` default 100s via `PI_STREAM_FIRST_EVENT_TIMEOUT_MS`; `streamIdleTimeoutMs` default 120s), `providerRetryWait`, `fetch: FetchImpl` override, `cwd`, `execHandlers` (Cursor); plus Simple-level: `reasoning: Effort`, `disableReasoning`, `hideThinkingSummary`, `textVerbosity: low|medium|high`, `thinkingBudgets: {[effort]: tokens}`, `toolChoice`, `serviceTier`, `kimiApiFormat`, `syntheticApiFormat`, `preferWebsockets`, `openrouterVariant` (":nitro" etc.), `antigravityEndpointMode`, `fallbacks` (Anthropic server-side fallback chain).
- `ToolChoice = "auto"|"none"|"any"|"required"|{type:"function",name}|{type:"function",function:{name}}|{type:"tool",name}` (types.ts:96-103); per-provider remaps in stream.ts:1278-1331 (`required→any` for Anthropic/Google, `any→required` for OpenAI; Google named force = `{mode:"ANY", allowedFunctionNames:[name]}`).
- **Tool wire definition** (`Tool`, types.ts:864-896): `name`, `description`, `parameters: TSchema` (Zod v4 | ArkType | raw JSON Schema), `strict?`, `customFormat? {syntax:"lark"|"regex", definition}` (OpenAI grammar custom tools), `customWireName?`, `examples?` (rendered as `<examples>` in native call syntax appended to the wire description).

## 1.6 Catalog: models and capability metadata

**`Model`** (catalog/types.ts:683-795) — the load-bearing metadata record: `id`, `requestModelId?` (wire id when different), `reasoningMode?: "pro"`, `name`, `api`, `provider` (free string; `KnownProvider` enumerates built-ins), `baseUrl`, `reasoning: boolean`, `input: ("text"|"image")[]`, `imageInputDecoder?: "stb"`, `supportsTools?` (false is the only negative signal), `cost: {input, output, cacheRead, cacheWrite}` **($/million tokens)**, `premiumMultiplier?`, `contextWindow: number|null`, `maxTokens: number|null`, `omitMaxOutputTokens?`, `headers?`, `transport?: "pi-native"`, `preferWebsockets?`, `useResponsesLite?`, `contextPromotionTarget?` (model to switch to when context promotion triggers), `compactionModel?`, `remoteCompaction?`, `priority?`, `thinking?: ThinkingConfig`, `compat: CompatOf<api>` (fully-resolved), `compatConfig?` (sparse authored form), `applyPatchToolType?: "freeform"|"function"`, `isOAuth?`.

**`ThinkingConfig`** (33-90): `mode: "effort"|"budget"|"google-level"|"anthropic-adaptive"|"anthropic-budget-effort"`, `efforts: Effort[]` (ordered), `defaultLevel?`, `effortMap?` (effort→wire value), `supportsDisplay?`, `effortRouting?` (per-effort wire-id, incl. `"off"`), `effortBudgets?`, `suppressWhenOff?`, `requiresEffort?` (endpoint rejects disabled thinking → clamp to lowest supported effort, stream.ts:1391-1406).

**Compat matrix**: `OpenAICompat` (~60 flags, types.ts:167-354: developer-role, multiple system messages, reasoning formats `openai|openrouter|zai|qwen|qwen-chat-template`, disable modes, `maxTokensField`, Mistral tool-id shape, thinking-as-text, `reasoning_content` replay for local llama.cpp KV-cache stability, tool_choice capability trio, moonshot schema flavor, stream markup healing, `whenThinking` full alternate view, …), `AnthropicCompat` (361-429: strict tools, adaptive thinking downgrade, long cache retention, mid-conversation system, forced tool choice, sampling params, unsigned thinking replay, builtin-tool-name escaping; resolved adds `officialEndpoint`/`signingEndpoint`), `DevinCompat`. `buildModel` materializes compat once; handlers only read.

- **`Effort`** (catalog/effort.ts): `"minimal"|"low"|"medium"|"high"|"xhigh"|"max"`. Agent-side **`ThinkingLevel`** (agent/src/thinking.ts) adds `"inherit"` and `"off"`.
- Bundled registry: `getBundledModel(provider, id)` over `models.json`; **`calculateCost(model, usage)`** (catalog/models.ts:46-54): `cost.X = (model.cost.X/1e6) * (usage.X + orchestration)`; total = sum. Called by every provider on each usage tick.
- Runtime `createModelManager`/`resolveProviderModels` (model-manager.ts): static bundled list + optional dynamic endpoint fetch + models.dev fallback, cached in `<agent-dir>/models.db` (TTL 2 h, fingerprint `merge-v3`), `dynamicModelsAuthoritative` pruning, variant collapse (effort-tier siblings folded into one logical model with `effortRouting`).

## 1.7 Usage, cost, context-window tracking

**`Usage`** (catalog/types.ts:96-149): `input` (non-cached), `output` (incl. thinking + tool args), `cacheRead`, `cacheWrite`, `totalTokens`, `orchestration? {input, cacheRead, output}` (billed, not replayable), `premiumRequests?`, `reasoningTokens?` (subset of output; undefined = unknown), `cttl? {ephemeral5m, ephemeral1h}` (Anthropic cache-write TTL split), `server? {webSearch, webFetch}`, `cost {input, output, cacheRead, cacheWrite, total}` (USD).

Context tracking (agent/src/compaction/compaction.ts): `calculateContextTokens(usage)` = `totalTokens || sum(components)` minus orchestration (214-221); `calculatePromptTokens` = input+cacheRead+cacheWrite (223); `contextSnapshot` stamped on assistant messages gives authoritative prompt tokens at send time; `compactionContextTokens(providerTokens, storedEstimate)` = max of both so on-wire compression can't defeat the trigger (314). Token estimation: `countTokens` = native cl100k when `PI_TOKENIZER_ACCURATE=1` else `(utf8len+3)>>2` (agent/src/tokenizer.ts).

Provider quota reporting: normalized `UsageReport {provider, fetchedAt, limits: UsageLimit[], resetCredits?, notes?}` with `UsageLimit {id,label,scope,window,amount{used,limit,remaining,usedFraction,…,unit},status}` (ai/src/usage.ts) + per-provider fetchers (claude, gemini, github-copilot, openai-codex incl. banked reset credits, zai, …) and `CredentialRankingStrategy` for smart credential selection.

## 1.8 Compaction (app/agent layer, `agent/src/compaction/`)

`CompactionSettings` (161-182) defaults (190-201): `{enabled:true, strategy:"context-full" ("context-full"|"handoff"|"shake"|"snapcompact"|"off"), thresholdPercent:-1, thresholdTokens:-1, midTurnEnabled:true, keepRecentTokens:20000, autoContinue:true, remoteEnabled:true, remoteStreamingV2Enabled:true}`; `DEFAULT_RESERVE_TOKENS = 16384`; effective reserve = `max(15% of window, reserve)` with small-window recovery when the default is impossible (263-288); `shouldCompact(contextTokens, contextWindow, settings)` (293). Cut-point search keeps recent turns (`findCutPoint`); summarization prompts under `compaction/prompts/*.md`; `CompactionResult {summary, shortSummary?, firstKeptEntryId, tokensBefore, details?, preserveData?}`; branch summarization, tool-result pruning (`pruning.ts`), tree-shaking (`shake.ts`), tool-protection, plus Codex provider-native "remote compaction" (v1 compact endpoint + v2 streaming `compaction_trigger`) classified by `CodexCompactionMetadata {trigger: manual|auto, reason: user_requested|context_limit|model_downshift|comp_hash_changed, phase: standalone_turn|pre_turn|mid_turn, strategy: memento|prefix_compaction}` (ai/types.ts:326-348). Compaction operates on session entries (`SessionEntry` union in coding-agent `session/session-entries.ts:208`: message, compaction, branch_summary, custom_message, model_change, thinking-level change, …) and writes a `CompactionEntry` that replaces the prefix at replay.

## 1.9 Prompt caching

- `cacheRetention: "none"|"short"|"long"` request option; Anthropic maps to `cache_control {type:"ephemeral", ttl 5m|1h}` breakpoints with `supportsLongCacheRetention` gate; OpenAI responses `prompt_cache_retention: "24h"` gate `supportsLongPromptCacheRetention`.
- `promptCacheKey` / fallback `sessionId` → OpenAI `prompt_cache_key`, xAI `x-grok-conv-id` header (`promptCacheSessionHeader`).
- **Append-only context mode** (`agent/src/append-only-context.ts`): `StablePrefix` freezes system prompt + normalized tool spec bytes (fingerprinted; `invalidate()` on MCP reconnect) and `AppendOnlyLog` keeps provider-level messages append-only (`replaceTail` reserved for compaction), so only the newest delta misses provider prefix caches. Related: `pruneToolDescriptions`, stable `i` intent field exclusion, soft tool requirements avoiding tool_choice flips — all cache-hit-rate preservers.

## 1.10 Auth: API keys, OAuth, rotation

- **`ApiKey = string | ApiKeyResolver`** (`ai/src/auth-retry.ts:40`); resolver `(ctx: {lastChance, error, previousKey?, signal?}) → string|undefined` drives the central **a/b/c policy**: (a) initial resolve, (b) refresh same account (`lastChance:false`), (c) rotate to sibling (`lastChance:true`); `AUTH_RETRY_STEPS = [false, true]`. Streaming driver (stream.ts:1011-1126) buffers replay-safe events (just `start`) and retries with a fresh key when a retryable auth outcome (401 or usage-limit phrasing/429) arrives before any replay-unsafe event; `withAuth`/`withOAuthAccess` are the non-streaming equivalents.
- **`AuthStorage`** (`ai/src/auth-storage.ts`, 6.6 kLOC + SQLite store): credentials per provider = `{type:"api_key", key}` or `{type:"oauth", refresh, access, expires, enterpriseUrl?, projectId?, email?, accountId?, apiEndpoint?}` (registry/oauth/types.ts:4-13); multi-account pools with session stickiness (`getOAuthAccess(provider, sessionId)`), refresh leases/fences, usage-limit blocks with scopes (`tier:fable`), credential health checks, disabled causes, usage/cost history tables.
- OAuth login flows per provider under `ai/src/registry/*` (~55 providers: anthropic, openai-codex (+device), github-copilot, google-gemini-cli, google-antigravity, qwen-portal, kimi-code, minimax, zhipu, …), flow types: loopback callback (with short `launchUrl`), device code, paste-code.
- **Auth broker/gateway** (`ai/src/auth-broker/`, `auth-gateway/`): an HTTP sidecar that owns credentials for containerized installs; `transport:"pi-native"` streams via the gateway.

## 1.11 Approval flow

Declared on tools (`agent/src/types.ts:588-600`): `ToolTier = "read"|"write"|"exec"`; `ToolApproval = tier | {tier, reason?, override?} | (args)=>decision`; plus `formatApprovalDetails(args)`. Enforced in the host (`coding-agent/src/tools/approval.ts`): `ApprovalMode = "always-ask"|"write"|"yolo"` maps to max auto-approved tier (read/write/exec); per-tool user config `tools.approval.<name>: allow|deny|prompt`; resolution order = tool decision → user override → mode-tier comparison; `override:true` force-prompts even in permissive modes (except yolo); `deny` throws; the actual prompting/blocking is done in `beforeToolCall` at the host layer (the loop core knows nothing of approvals beyond the hook).

## 1.12 Thinking/reasoning handling

- Request: `reasoning: Effort` + `disableReasoning` + `thinkingBudgets` + `hideThinkingSummary` + dynamic `getReasoning()/getDisableReasoning()` per call.
- Anthropic (stream.ts:1447-1538): adaptive mode sends `effort` (mapEffortToAnthropicAdaptiveEffort); budget mode sends `thinkingBudgetTokens` from `thinkingBudgets[effort] ?? ANTHROPIC_THINKING` = {minimal:1024, low:4096, medium:8192, high:16384, xhigh:32768, max:32768}; interleaved thinking default on (`PI_NO_INTERLEAVED_THINKING` opt-out); budget squeezed to keep ≥ `MIN_OUTPUT_TOKENS=1024` output; thinking disabled if budget ≤0; `hideThinkingSummary` → `thinking.display:"omitted"`.
- Google: `google-level` mode sends `thinkingLevel`; budget mode ladder (2.5-family: minimal 128, low 2048, medium 8192, high+ 24576 flash / 32768 pro; unknown → dynamic `-1`); `suppressWhenOff` forces explicit off on the wire.
- OpenAI-family: `reasoning_effort` string with per-model `effortMap`/compat remaps; `disableReasoning` per `reasoningDisableMode`; `textVerbosity`; Responses `reasoning.summary` control.
- Bedrock ladder differs (low:2048, xhigh:16384). `OPENAI_MAX_OUTPUT_TOKENS = 64000` request ceiling (ai/types.ts:58).

## 1.13 Error/abort taxonomy

- `ai/src/error/*`: typed classes, `errorId` bit flags (`AIError.Flag.Abort`, `ThinkingLoop`, usage-limit classifiers), rate-limit reason parsing, retry-after handling, per-provider error mapping.
- Abort: standard `AbortSignal` threading; `abortReasonText(signal)` (agent-loop.ts:1696) surfaces custom string/Error reasons, defaults to "Request was aborted"; `ToolScopedAbortReason {kind:"tool-scoped-abort", message, toolCallMessages, defaultToolCallMessage}` labels only the offending call in a batch (122-136); `retainCompletedToolCalls` drops tool calls that never reached `toolcall_end` from aborted/errored messages and stamps `stopDetails {type:"stream_interrupted_after_content", …}` (1591-1616); `recoverTransientErrorToolTurn` converts a stream-read error after complete tool calls back into a usable `toolUse` turn (1618-1648).
- Telemetry: opt-in OTel GenAI spans `invoke_agent`/`chat`/`execute_tool` + `AgentRunSummary` (chats by stop reason, tool counters ok/error/skipped/blocked/timeout/aborted, usage totals, estimated USD, error histogram, stepCount) and `AgentRunCoverage` (tools available/invoked/unused, models/providers used) (run-collector.ts:68-117).

---

# PART 2 — ai.zig app-facing surface

## 2.1 Module map (`src/`)

`provider` (V4 spec: model vtables, 21-tag StreamPart, prompt/content, usage, errors+Diagnostics, canonical JSON wire codec), `provider_utils` (HttpTransport over std.http.Client, SSE decoder, retry engine, partial-JSON repair, `schemaFromType`, multipart, guarded downloads), `ai` (generate/stream text+objects, ToolLoopAgent, prompt conversion, registry, middleware, telemetry, broadcast streaming pipeline, UI message stream), `mcp`, `ffi`, provider packages `anthropic`, `openai`, `google`, `openai_compatible` (+5 presets: groq/deepseek/mistral/together/fireworks), `openrouter`, `xai`, `otel`.

Conventions: `std.Io` passed by value everywhere; provider `doGenerate/doStream` receive a caller-owned arena; high-level results own an internal arena and expose `deinit()` (streams `deinit(io)`); provider stream parts are **borrow-until-next-call**.

## 2.2 generateText / streamText

`ai.generateText(io, gpa, GenerateTextOptions) → GenerateTextResult` (generate_text.zig:344). **`GenerateTextOptions`** (216-251):

```zig
model: registry.LanguageModelRef,          // union(enum){ id: []const u8, model: provider.LanguageModel }
instructions: ?Instructions,               // union: text | message | messages (system)
prompt: ?PromptValue,                      // union: text | messages
messages: ?[]const ModelMessage,
allow_system_in_messages: bool = false,
tools: []const NamedTool = &.{},
tool_choice: ?ToolChoice,                  // union(enum){auto, none, required, named: []const u8}
active_tools / tool_order: ?[]const []const u8,
stop_when: []const StopCondition = &.{},   // stepCount(n) / hasToolCall(names) / loopFinished()
prepare_step: ?PrepareStep,
repair_tool_call: ?RepairToolCall, refine_tool_input: ?[]const RefineToolInput,
max_output_tokens/temperature/top_p/top_k/presence_penalty/frequency_penalty: ?f64,
stop_sequences, seed,
reasoning: ?provider.ReasoningEffort,      // provider_default|none|minimal|low|medium|high|xhigh
headers: ?provider.Headers,
provider_options: ?provider.ProviderOptions,   // JSON under provider namespaces
max_retries: u32 = 2,
timeout: ?TimeoutConfiguration,            // total_ms | granular{total,step,chunk,tool,per-tool}
tools_context / runtime_context: ?std.json.Value,
output: ?Output,                           // text()/object(schema)/array/choice/json strategies
callbacks: Callbacks,                      // on_start/on_step_start/on_language_model_call_start|end/
                                           // on_tool_execution_start|end/on_step_end/on_end/on_error/on_abort
telemetry: TelemetryOptions,
tool_approval_secret: ?[]const u8,         // HMAC-SHA256 signing of approval requests
diag: ?*provider.Diagnostics,
```

`StreamTextOptions` (stream_text.zig:75-115) = same + `transforms: []const StreamTransform`, `on_chunk`, `on_error`, `on_abort`, `include_raw_chunks`.

**Loop semantics**: `while (natural_continue)` (generate_text.zig:516-555); `natural_continue = outcome.should_continue` where `shouldContinue(client_call_count, client_output_count, denied_approval_count, pending_deferred_count) = (calls>0 && calls==outputs+denials) || pending_deferred>0` (tool_execution_common.zig:413-422), then `stop_when` conditions can end it (empty stop_when = single step; agent default `stepCount(20)`). Tool approvals from a previous run are **replayed before step zero** (`replayInitialToolApprovals`, 318-342).

**`prepare_step`** (144-186) receives `{steps, step_number, model, instructions, initial_instructions, messages, initial_messages, response_messages, tools_context, runtime_context}` and may sparsely return `{model, tool_choice, active_tools, tool_order, instructions, messages, tools_context, runtime_context, provider_options}` — replacing **messages** is supported and deep-cloned into the call arena (682-708). Note it has **no** per-step `reasoning`/sampling override (those ride `provider_options`).

**`StreamTextResult`** (stream_text.zig:204+): sole pipeline driver `next(io) → ?TextStreamPart`; derived cursors `fullStream()`, `textStream()`, `partialOutputStream()`, `elementStream(diag)`; promise-like accessors that drain the stream: `text, reasoningText, steps, finalStep, finishReason, rawFinishReason, totalUsage, usage, responseMessages, content, toolCalls, toolResults, warnings, request, response, providerMetadata, output`, plus `consumeStream`, `attachCleanup(StreamCleanup)`, `deinit(io)`. Broadcast log retention is unbounded for the result lifetime (contracts.md:12-21); cursors are mutex-guarded and thread-safe.

**`TextStreamPart`** — exact 26-tag union (stream/parts.zig:92-119): `text_start, text_end, text_delta, reasoning_start, reasoning_end, reasoning_delta, custom, tool_input_start, tool_input_end, tool_input_delta, source, file, reasoning_file, tool_call, tool_result, tool_error, tool_output_denied, tool_approval_request, tool_approval_response, start_step {request, warnings}, finish_step {response, usage, performance, finish_reason, raw_finish_reason, provider_metadata}, start, finish {finish_reason, raw_finish_reason, total_usage}, abort {reason: ?[]const u8}, err {error_value: json, error_code: ?anyerror}, raw`.

Provider **`StreamPart`** — 21 tags (provider/language_model.zig:583-630): text/reasoning start|delta|end, tool_input_start|delta|end, `tool_approval_request`, `tool_call` (input = stringified JSON), `tool_result` (`is_error?`, `preliminary?`, `dynamic?`), `custom`, `file`, `reasoning_file`, `source`, `stream_start {warnings}`, `response_metadata`, `finish {usage, finish_reason}`, `raw`, `err`.

**Usage** (language_model.zig:374-393): `Usage {input_tokens: {total?, no_cache?, cache_read?, cache_write?}, output_tokens: {total?, text?, reasoning?}, raw?: json}` — all optional; no cost. `FinishReason {unified: stop|length|content_filter|tool_calls|error|other, raw?}`. Per-step `StepPerformance`/`ModelCallPerformance` include `time_to_first_output_ms`, tokens/sec, chunk-timing percentiles (parts.zig:121-150).

## 2.3 ToolLoopAgent (agent.zig)

`ToolLoopAgentSettings` (182-219): `model`, `id?`, `instructions?`, `allow_system_in_messages`, `tools`, `tool_choice?`, `active_tools?`, `tool_order?`, `stop_when: ?[]const StopCondition` (**null → default `stepCount(20)`**; explicit empty slice → single-step), `prepare_step?`, `repair_tool_call?`, `refine_tool_input?`, sampling fields, `reasoning?`, `provider_options?`, `headers?`, `max_retries=2`, `timeout?`, `tools_context?/runtime_context?`, `output?`, `tool_approval: ?{secret}`, `telemetry`, `callbacks: LifecycleCallbacks` (on_start/on_step_start/on_tool_execution_start|end/on_step_end/on_end), `call_options_schema: ?Schema` (validates per-call options JSON), `prepare_call: ?PrepareCall`, `diag?`.

`agent.generate(io, gpa, AgentCallParameters)` / `agent.stream(...)`; `AgentCallParameters {options?: json, prompt?, messages?, timeout?, callbacks, transforms}` (78-85). `prepare_call` receives fully resolved `PrepareCallOptions` (callbacks absent) and may sparsely replace nearly everything, including model, tools, stop conditions, prepare_step, output, telemetry, tool-approval config (89-159); replacing `prompt` clears inherited `messages` and vice versa. Settings + call callbacks are merged; stream results retain the prepared-call arena via `attachCleanup`. Type-erased `ai.agent_api.Agent` vtable (`generate_fn`/`stream_fn`, 26-61) for embedding layers. Agent requests add UA suffix `ai-sdk-zig-agent/tool-loop`.

## 2.4 Tools

`ai.NamedTool {name, tool: Tool}`; **`Tool`** (tool.zig:153-175): `kind: function|dynamic|provider_defined|provider_executed`, `name?`, `description: ?{text | resolver(tool_context)}`, `input_schema: provider_utils.Schema` (from `schemaFromType(T)` — draft-07 camel-cased schema + Zig validator, `additionalProperties:false`; or `rawSchema(json, validator?)`), `output_schema?`, `context_schema?`, `execute: ?ToolExecute` — `fn(ctx, io, arena, input: std.json.Value, options: ToolExecutionOptions{tool_call_id, messages, context}) anyerror!ToolOutput` where `ToolOutput = {value: json} | {stream: PreliminaryStream}` (every non-final streamed value is preliminary; excluded from step records), `needs_approval: .no|.yes|.{resolver(input, options)→bool}`, `on_input_start/on_input_delta/on_input_available` callbacks, `to_model_output` (converts output → `ToolResultOutput`), `metadata`, `provider_options`, `strict?`, `input_examples?`, provider-defined fields, `supports_deferred_results`.

Execution contract (contracts.md:31-51): approved client tool calls execute **concurrently** in isolated arenas; blocking results assembled in tool-call order; streaming interleaves in completion order after `model_call_end`; a thrown tool error becomes `tool_error` data fed back to the model (never cancels siblings); per-tool timeouts (`timeout.granular.tools[]`) surface as tool-error outputs; model retries never retry tools; duplicate tool-call ids are an open item (last-write-wins).

## 2.5 Approvals

Approval implemented for function tools: `needs_approval` blocks execution and emits `tool_approval_request {approval_id, tool_call_id}`; the loop halts (output count < call count) until the app supplies `tool_approval_response {approval_id, approved, reason?}` in the next prompt's tool message; approved calls replay before step zero; denial becomes an `execution-denied` tool result (tools.md:140-159). Optional `tool_approval_secret` signs requests with HMAC-SHA256 binding approval id, tool-call id, tool name, and a canonical-JSON input digest; deliberately does not bind user/run/model/expiry/nonce (contracts.md:75-87).

## 2.6 Messages

`ai.ModelMessage` union `{system {content: []const u8}, user {content: text|parts(text|image|file)}, assistant {content: text|parts(text|custom|file|reasoning|reasoning_file|tool_call|tool_result|tool_approval_request)}, tool {content: [](tool_result|tool_approval_response)}}` with declared wire tags (message.zig:396-429). `ToolResultOutput = text|json|execution_denied|error_text|error_json|content(parts)` (277-316). **`cloneModelMessages(arena, msgs)`** (434-438) deep-copies through the canonical wire codec — the sanctioned way to move history into longer-lived storage. `provider.wire.stringifyAlloc`/`parse` give a stable JSON serialization of the full message vocabulary.

## 2.7 Providers

Factories (all take explicit key + `HttpTransport`; optional injected `EnvLookup` — **no implicit process env**): `anthropic.createAnthropic` (error{InvalidArgumentError}!), `openai.createOpenAi` (Responses default + Chat Completions; also embeddings/image/speech/transcription/realtime), `google.createGoogleGenerativeAi`, `openai_compatible.createOpenAiCompatible` (+ vendor presets), `openrouter.createOpenRouter`, `xai.createXai`. Env names table in providers/index.md:54-66. Model ids pass through, **no catalog validation** (providers/index.md:6-7). Bare-string `LanguageModelRef.id` resolves via default OpenRouter runtime when compiled in (`-Ddefault-openrouter`), `ai.setDefaultRuntime/setDefaultEnv/setDefaultProvider`.

`providerOptions` passthrough (JSON namespaces, canonical + custom-name overlay):
- **Anthropic** (`anthropic/options.zig:18-35`): `sendReasoning`, `structuredOutputMode: outputFormat|jsonTool|auto`, `thinking {type: adaptive|enabled|disabled, budgetTokens?, display?: omitted|summarized}`, `disableParallelToolUse`, `cacheControl {type: ephemeral, ttl?: 5m|1h}`, `metadata.userId`, `mcpServers`, `container`, `anthropicBeta: []string`, `toolStreaming`, `effort: low|medium|high|xhigh|max`, `taskBudget`, `speed: fast|standard`, `inferenceGeo`, `fallbacks`, `contextManagement`. Per-message/part `cache_control` via message-level `provider_options` (prompt.zig; validates non-cacheable placement + breakpoint limit). `ReasoningEffort` maps to adaptive thinking for capable families or an explicit token budget for older ones; known families carry max-output + structured-output capability data (providers/anthropic.md:41-45; `anthropic/capabilities.zig`).
- **OpenAI** (`openai/options.zig`): Chat `{logit_bias, logprobs, parallel_tool_calls, user, reasoning_effort, max_completion_tokens, store, metadata, prediction, service_tier(auto|flex|priority|default), strict_json_schema, text_verbosity, prompt_cache_key, prompt_cache_options, prompt_cache_retention, safety_identifier, system_message_mode, force_reasoning}`; Responses adds `{conversation, include, instructions, max_tool_calls, previous_response_id, reasoning_mode, reasoning_context, reasoning_summary, truncation, context_management, allowed_tools {tool_names, mode}, pass_through_unsupported_files}`.
- Structured output per provider (structured-output.md:59-75); Anthropic falls back to a forced synthetic `json` tool for older families.

## 2.8 Cancellation, retries, errors

Three layers (contracts.md:53-67): (1) unblocking a waiting `next()` — sub-millisecond, any thread; (2) in-flight I/O — cancels at the next cancellation point (`io.async`/`Future.cancel`); (3) **user tool code is cooperative only** (`io.checkCancel()`). Timeouts (`TimeoutConfiguration`) drive the abort path; `on_abort` fires with `AbortEvent {call_id, reason: "timeout"|"canceled"}` (generate_text.zig:383-395); streaming emits an `abort` part. Retries: model calls only, `max_retries=2` (3 attempts), 2000 ms doubling, 408/409/429/5xx retryable, first non-retryable error returned unchanged, `RetryError` + Diagnostics on exhaustion (core-concepts.md:144-155). Errors: 36-category `provider.Error` + optional `*Diagnostics` with owned structured context; **mid-stream provider failures are stream data (`err` parts)**, machinery failures are Zig errors.

## 2.9 MCP, middleware, telemetry, downloads

- MCP client (mcp.md): stdio/legacy-SSE/streamable-HTTP transports, init handshake, `listTools` → `toolsFromDefinitions`/`client.tools()` bridging into `NamedTool` (automatic schemas become dynamic tools normalized with additionalProperties:false; isError → model-visible tool errors); sessions with `Mcp-Session-Id`, Last-Event-ID resume; auth = `AuthHook` called once after a 401 (full OAuth intentionally not implemented).
- Middleware: `wrapLanguageModel`, `extractReasoningMiddleware` (parse `<think>`-style tags from text), `extractJsonMiddleware`, `simulateStreamingMiddleware` (root.zig:50-56).
- Telemetry: `TelemetryOptions` per call + registered dispatchers; `otel` module; C ABI exposes telemetry callbacks.
- Download policy for URL file parts: http/https only, private/special ranges and localhost blocked at string level, redirect hops re-validated, 2 GiB cap; **no hostname-vs-resolved-address check yet** (contracts.md:89-100).

---

# PART 3 — Mapping and gap list

Legend: **exists** (direct equivalent), **partial** (equivalent with semantic/coverage differences the port must bridge), **missing** (must be built), **app-layer** (upstream keeps it above the SDK too — port it into pi.zig, not into ai.zig).

| Upstream concept | ai.zig equivalent | Status |
|---|---|---|
| `streamSimple` + 14-API dispatch | `provider.LanguageModel.doStream` + factories (anthropic, openai chat+responses, google, openai_compatible+5 presets, openrouter, xai) | **partial** — no bedrock, vertex, gemini-cli/antigravity, codex-responses (OAuth WS/SSE), ollama-native (compatible covers basics), cursor/gitlab/devin agents, kimi/synthetic routers, pi-native gateway transport |
| `AssistantMessageEvent` (12 tags, partial-carrying) | provider `StreamPart` (21) / `TextStreamPart` (26) | **exists**, different vocabulary: ai.zig has no accumulated `partial` on every event (port keeps its own accumulator, as upstream providers do internally); thinking → `reasoning_*`; `toolcall_end` → `tool_input_end`+`tool_call` |
| `EventStream` (push + result promise, replayable) | Broadcast log + cursors + promise-like accessors | **exists** (stronger: multi-cursor replay, thread-safe) |
| `agentLoop`/`agentLoopContinue` | `generateText`/`streamText` multi-step loop; `ToolLoopAgent` | **partial** — see "loop semantics differences" below |
| `AgentEvent` (turn/message/tool lifecycle) | `Callbacks` (on_step_start/on_step_end/on_tool_execution_*) + `start_step`/`finish_step` parts | **partial** — no `turn_end`-with-toolResults aggregation, no message_start/end vocabulary; port synthesizes AgentEvents above the stream |
| `Agent` class (state, queues, listeners, busy-error) | — (type-erased `agent_api.Agent` is just generate/stream vtables) | **missing / app-layer** — port owns it |
| **Mid-run steering** (`steer()`, injection at boundaries, mid-batch interrupt of remaining tools, interruptible-tool 250 ms poll) | none; `prepare_step.messages` can replace history between steps; cancellation kills the whole stream | **missing** — key design decision below |
| Follow-ups / asides / `onBeforeYield` outer drain | none | **missing / app-layer** |
| `interruptMode` "immediate"/"wait", `interruptible` tools, IRC interrupts | per-tool cooperative cancel via `io.checkCancel` + per-tool timeout | **missing** (loop-level policy); building blocks exist |
| Process-wide pause gate (`agentPauseGate`) | none | **missing / app-layer** (easy on `Io` primitives: mutex+event) |
| `deadline` (absolute epoch ms) | `TimeoutConfiguration.total_ms` (relative) | **partial** — convert at call site; but upstream checks deadline at loop boundaries and gracefully ends with agent_end, ai.zig timeout aborts with error.Canceled |
| `convertToLlm` + `AgentMessage` custom roles | fixed `ModelMessage` union; `custom` content parts only | **missing** — port defines its own `AgentMessage` (tagged union incl. Pi extras: timestamp, synthetic, steering, attribution, usage, stopReason, errorMessage, model/provider stamps, details, useless, prunedAt) and lowers to `ModelMessage` per call — exactly upstream's `convertToLlm` seam |
| `transformContext` / `transformProviderContext` | prepare_step (messages/instructions/tools/provider_options) | **partial** |
| `syncContextBeforeModelCall` | prepare_step (instructions + active_tools/tool_order) | **exists** via prepare_step |
| `getModel()` mid-run switch (context promotion, retry fallback) | `PrepareStepResult.model` | **exists** |
| `getReasoning()`/`getDisableReasoning()`/`getServiceTier()` per call | no per-step reasoning field; only static `reasoning` + per-step `provider_options` overlay | **partial** — port must re-issue calls per step (own loop) or encode via provider_options |
| `getToolChoice` per turn + `SoftToolRequirement` remind-then-escalate | `PrepareStepResult.tool_choice` (hard only) | **partial** — soft-requirement lifecycle (id tracking, reminder injection, skip-detour-results, one-turn force, escalation cap 3) is port logic |
| `ToolChoice` shapes (7 forms incl. OpenAI function nesting) | `ai` ToolChoice {auto,none,required,named} → provider {auto,none,required,tool} | **exists** (upstream "any" ≡ required) |
| Tool definition `AgentTool` (label, hidden, loadMode, summary, concurrency, lenientArgValidation, interruptible, intent, matcherDigest/Paths/Entries, approval tier, formatApprovalDetails, renderCall/renderResult, deferrable, customWireName, customFormat, examples) | `NamedTool`/`Tool` (schema+validator, execute, needs_approval, description resolver, input callbacks, to_model_output, input_examples, strict, provider-defined) | **partial** — Pi-specific fields are app-layer metadata on the port's own tool type wrapping `ai.NamedTool`; grammar custom tools (`customFormat`/`customWireName`) missing in ai.zig wire; `examples` → `input_examples` exists but Pi's dialect-rendered `<examples>` block is port logic |
| Tool result: `content:(text|image)[]`, `details`, `isError`, `useless`, streaming `onUpdate` | `ToolOutput {value|stream(PreliminaryStream)}`, `ToolResultOutput.content` parts (text/file/image), `error_text/error_json`, preliminary flag | **partial** — `details` (UI payload) and `useless` don't exist in ai.zig vocabulary; carry them in the port's tool record, emit to model via `to_model_output` |
| Batch concurrency `shared`/`exclusive` (+fn) | always-concurrent execution, results in call order | **partial** — port needs its own scheduler if it owns the tool loop (recommended); if delegating to ai.zig loop, exclusivity is missing |
| Argument validation + `lenientArgValidation` + `__parseError` passthrough | schema validator from `schemaFromType`; `repair_tool_call` + `refine_tool_input` hooks | **partial** |
| `beforeToolCall` (block/mutate) / `afterToolCall` (override) / `transformToolCallArguments` | `needs_approval` resolver (block), `refine_tool_input` (mutate input), `to_model_output` (override output) | **partial** — semantics close enough if port owns the loop; ai.zig-loop path lacks synchronous block-with-reason producing an error result |
| `transformAssistantMessage` (mutate finalized message before context/UI/tools) | `StreamTransform` (part-level) | **partial** — port applies its macro expansion on its own accumulated message |
| Approval flow: tier (read/write/exec) × mode (always-ask/write/yolo) × user policy (allow/deny/prompt), prompt formatting | `needs_approval` + approval request/response parts + HMAC signature + execution-denied result + pre-step replay | **partial** — ai.zig models the mechanism (block, respond next prompt, replay); Pi's policy table and interactive prompt are app-layer; note the flow difference: upstream blocks **inline** via beforeToolCall and emits an error tool result in the same turn; ai.zig **halts the loop** and resumes on the next call — the port's UI must bridge (likely keep Pi's inline model by owning the loop) |
| Loop continuation decision | upstream: `(stopReason∈{toolUse,stop}) && toolCalls>0`, plus continues on steering/asides/follow-ups and `pause_turn` (≤8) even with no tools; unbounded steps | ai.zig: `calls>0 && calls==outputs+denials`, then `stop_when` (default 1 step; agent 20) | **partial — semantics differ**; see below |
| `length`-stop with dangling tool calls → placeholder results + continue | not handled (finish_reason length ends step; tool calls with truncated args would fail validation) | **missing** — port logic |
| Placeholder/synthetic tool results for aborted/errored/skipped calls (`SyntheticToolResultDetails`) | none (aborted stream = cancel; no pairing repair) | **missing** — port logic |
| Provider-error-as-message (loop never throws; error AssistantMessage persisted) | `err` stream part is data, but `generateText` returns Zig errors; steps record what completed | **partial** — port converts stream `err`/`abort` parts + Zig errors into its Pi-style assistant error message |
| Abort with reason, tool-scoped abort labels, `retainCompletedToolCalls` | cancel (io) + `abort {reason}` part; no structured per-tool labels; partial parts retained in broadcast log | **partial/missing** — port implements reason plumbing and completed-call retention over its own accumulator |
| Retry: provider-level (retry-after, maxRetryDelayMs cap, empty-completion retry, thinking-loop cook, harmony re-sample) | retry engine (2 retries, backoff, 408/409/429/5xx) | **partial** — advanced re-sample policies missing |
| Stream watchdogs (first-event 100 s / idle 120 s, env overrides) | `timeout.granular.chunk_ms` (inter-part gap) | **partial** — no separate first-event budget; port sets chunk_ms and its own first-part timer |
| `ApiKeyResolver` + a/b/c credential rotation with replay-safe buffering | api key resolved at call time via settings/`EnvLookup` (rotatable without rebuilding models); no error-driven rotation | **missing** — port implements rotation above ai.zig (retry the whole step with a new key; safe because ai.zig surfaces auth failures before content) |
| OAuth login flows, AuthStorage (SQLite pools, refresh leases, usage-limit blocks, session stickiness), auth broker/gateway | none (explicit keys; MCP AuthHook seam) | **missing / app-layer** — big port item; independent of ai.zig |
| Provider in-flight caps (cross-process lease files) | none | **missing / app-layer** |
| Catalog: `Model` metadata (cost $/Mtok, contextWindow, maxTokens, thinking config, effortRouting, compat matrix), models.json, model manager + models.db cache, variant collapse | none by design ("model ids are passed through … not centrally validated against a catalog", providers/index.md:6) | **missing / app-layer** — port pi-catalog as a Zig data module; feed per-model knobs into ai.zig via factory config + `provider_options` |
| `calculateCost` and `usage.cost` on every message | `provider.Usage` has no cost | **missing** — trivial port over catalog cost table; note ai.zig usage maps cleanly: input↔no_cache, cacheRead↔cache_read, cacheWrite↔cache_write, output(total/reasoning)↔output+reasoningTokens |
| Context-window tracking (`contextSnapshot`, `calculateContextTokens`, compaction trigger floor) | per-step `usage` + `totalUsage` available | **missing / app-layer** (arithmetic over ai.zig usage) |
| Compaction (settings/thresholds/cut points/summarization/handoff/pruning/remote Codex) | none | **missing / app-layer** — port `agent/src/compaction` wholesale; summarization calls reuse `generateText` |
| Prompt caching: `cacheRetention` policy | Anthropic `cacheControl` (+ per-message `cache_control` breakpoints), OpenAI `prompt_cache_key/retention/options` via provider_options | **partial** — mechanism exists; the retention→breakpoint placement policy and cross-provider abstraction are port logic |
| `promptCacheKey`/`sessionId` affinity | OpenAI `prompt_cache_key` provider option | **partial** — per-provider affinity headers beyond OpenAI missing |
| Append-only context (StablePrefix + AppendOnlyLog) | none; but prompt conversion is deterministic and app controls message slices | **missing / app-layer** — port keeps its own provider-level log and byte-stable tool spec (needs care: ai.zig re-encodes JSON each call; byte-stability holds only if the port feeds identical inputs and ai.zig serialization is deterministic — verify with a conformance test) |
| Thinking levels: `Effort` minimal..**max** (+ ThinkingLevel off/inherit), `thinkingBudgets` ladders, `requiresEffort` clamps, `hideThinkingSummary`, interleaved-thinking betas | `ReasoningEffort` provider_default/none/minimal..xhigh (**no `max`**); Anthropic options `thinking{adaptive|enabled|disabled, budgetTokens, display}` + `effort` enum (has xhigh|max); OpenAI `reasoning_effort` string | **partial** — port owns the Effort→(budget|level|effort-string) mapping tables (§1.12) and drives ai.zig via `reasoning` + provider_options; `max` must map to xhigh or per-provider effort option |
| Owned in-band tool-calling dialects (glm/hermes/kimi/qwen3/xml/…: prompt rendering, history re-encoding, stream re-parse, fabricated-result abort) | none | **missing** — app-layer over ai.zig text streaming (send no tools, parse text) |
| Harmony-leak detection/recovery; leaked-thinking healing; stream markup healing | `extractReasoningMiddleware` covers the simple `<think>` tag case | **partial/missing** |
| Structured output | `Output` strategies + `generateObject`/`streamObject` | **exists** |
| Custom API registry / proxy StreamFn | custom `LanguageModel` vtable impl, `customProvider`, `ProviderRegistry`, middleware | **exists** |
| MCP tools | `mcp` module → NamedTool bridging | **exists** (OAuth-for-MCP is a seam only) |
| Telemetry (OTel GenAI spans, AgentRunSummary/Coverage) | telemetry dispatcher + events + otel module | **partial** — run-summary aggregation is port logic |
| Usage-limit reporting (`UsageReport`, ranking, reset credits) | none | **missing / app-layer** |
| Service tier per family (`ServiceTierByFamily`, priority→Anthropic `speed:fast`) | provider_options `service_tier` (OpenAI), `speed` (Anthropic) | **partial** — family classification + persistence coercion is port logic |
| Session serialization of messages | `provider.wire` canonical JSON + `cloneModelMessages` | **partial** — ai.zig serializes `ModelMessage` only; Pi's envelope fields (timestamp, usage, stopReason, api/provider/model, errorId, details, attribution, …) live on the port's AgentMessage, serialized by the port (upstream: JSONL of `SessionEntry` in coding-agent) |
| Tokenizer (`countTokens`, bytes/4 default) | none | **missing / app-layer** (trivial heuristic; optional native cl100k) |
| `EventLoopKeepalive`, `yieldIfDue` | N/A (threads/Io) | drop |

## 3.1 Explicit callouts requested

**Mid-run steering.** ai.zig has no queue poll between steps and no way to interrupt a running tool batch short of canceling the whole stream. Two viable port architectures:
1. **Port owns the loop (recommended, matches Pi).** Use ai.zig **one step at a time**: either `generateText/streamText` with `stop_when = stepCount(1)` (one model call; ai.zig still executes that step's approved tools and returns `responseMessages`), or drop to `LanguageModel.doStream` + port-owned tool execution. The port then re-implements Pi's `runLoopBody` verbatim: steering dequeue at boundaries, mid-batch skip via its own tool scheduler (shared/exclusive + interruptible signals over `io` cancellation), asides, follow-ups, soft tool choice, pause gate, placeholder results, error-as-message. This preserves *all* Pi loop semantics and only leases ai.zig's provider/streaming/validation machinery.
2. Delegate the loop to ai.zig and approximate steering via `prepare_step.messages` (injection works; interruption doesn't). Not recommended: loses interruptMode, skipped-tool pairing, pause_turn/length handling.

**Message-history ownership.** Upstream history is GC'd JSON; the loop deep-snapshots assistant messages before sharing. In ai.zig everything returned by a result **borrows the result arena** and dies at `result.deinit()`/`deinit(io)`; provider stream parts are borrow-until-next-call. A long-lived chat therefore must: keep one session-owned arena (or per-turn arenas chained), and after each step copy `responseMessages()`/step content via `message.cloneModelMessages(session_arena, msgs)` (message.zig:434) — the canonical deep-clone through the wire codec — before deinit-ing the step result. The port's AgentMessage store should be the single source of truth and lower to fresh `ModelMessage` slices per call (mirror of `convertToLlm`). Never retain `TextStreamPart` slices past the result lifetime.

**Compaction hooks.** Upstream compaction sits entirely above the loop (`transformContext` + session entries). ai.zig has zero compaction; the equivalent seam is: port compaction operates on the port's AgentMessage/SessionEntry store before lowering; `usage`/`totalUsage` from `finish_step` supply the trigger inputs; Codex remote compaction has no ai.zig backend (would need a codex provider first).

**Per-model capability metadata.** Entirely absent from ai.zig by design. The port carries pi-catalog (models.json → Zig data or embedded JSON parsed once via `buildModel`-equivalent), and uses it to (a) pick factory + model id (+`requestModelId` for wire), (b) clamp efforts (`ThinkingConfig.efforts`, `requiresEffort`), (c) compute cost (`calculateCost`), (d) drive compaction thresholds (`contextWindow`, `maxTokens`), (e) set provider_options (budgets, service tier, cache retention). The huge `OpenAICompat` matrix only matters for exotic OpenAI-compatible hosts; ai.zig's `openai_compatible` presets cover mainstream ones — port the compat flags incrementally, keyed by need.

**OAuth-style auth.** Upstream has full OAuth (device/loopback/paste flows, refresh, multi-account rotation, SQLite storage, broker/gateway sidecar). ai.zig deliberately has none (explicit keys; injectable `EnvLookup` allows rotation without rebuilding models; MCP `AuthHook` retry-after-401 seam). The port implements auth storage + flows itself and injects tokens per call; the a/b/c rotation loop wraps the ai.zig step call (retry the step with a fresh key on 401/usage-limit — ai.zig surfaces the status via Diagnostics/err parts).

**Prompt-cache control.** Exists in ai.zig only as raw provider options (`anthropic.cacheControl`+per-message `cache_control`, `openai.prompt_cache_key/retention`). Pi's `cacheRetention` abstraction, breakpoint placement strategy, stable-prefix mode, and cache-aware policies (soft tool choice, description pruning, `i`-field stability) are all port responsibilities.

**Session serialization.** Use `provider.wire` for the ModelMessage core; wrap in a port-defined envelope carrying Pi's metadata (timestamps, usage+cost, stopReason, errorMessage/errorId, model/provider/api, attribution, synthetic/steering flags, tool `details`, `useless`, `prunedAt`, contextSnapshot). Keep the JSONL SessionEntry design from coding-agent (`session-entries.ts:208-224`) since compaction/branching depend on entry granularity.

**Loop-semantics deltas to encode in the port spec** (upstream behavior wins):
1. Continue when `stopReason ∈ {toolUse, stop}` **and** tool calls exist — not only `tool_calls` finish reason.
2. `length` stop: never execute (truncated args); pair placeholders; continue the loop.
3. `pause_turn` stopDetails: re-sample up to 8 consecutive times.
4. Steering/asides/follow-ups can extend a run past the model's natural stop; ai.zig's `stop_when` never restarts a finished loop — port drives continuation itself.
5. No default step cap (Pi runs unbounded; deadline/steering are the brakes) vs ai.zig agent default `stepCount(20)`.
6. Provider errors/aborts terminate the run **gracefully with a persisted assistant error message + paired placeholder results**, never an exception to the host.
7. Tool-choice directives resolve once per logical turn and must not be re-consumed by retry re-samples.
8. Aborted streams retain only tool calls that reached `toolcall_end`.

**Recommended port shape** (1-line summary per layer): pi.zig defines `AgentMessage`/`SessionEntry` + its own `agentLoop` state machine (Part 1 semantics) over per-step ai.zig calls (`streamText` with `stop_when=stepCount(1)` or provider `doStream` + a port tool scheduler with shared/exclusive/interruptible semantics); pi-catalog becomes a Zig data package feeding factories/options; auth storage, compaction, approvals policy, steering queues, pause gate, cost/usage accounting, and dialects are pi.zig modules; ai.zig is consumed strictly for providers, streaming, schema validation, structured output, and MCP.
