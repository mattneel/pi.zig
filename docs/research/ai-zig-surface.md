# ai.zig application-facing surface — spec for the pi.zig agent core

Source of truth: `/home/autark/src/zig/ai.zig` at master HEAD `128433a` ("docs: close Phase 12 acceptance — v0.1.0 published and verified"). Package name `zig_ai`, version `0.1.0`, `minimum_zig_version = "0.16.0"` (`build.zig.zon`). All statements verified against source; citations are `path:line` in the ai.zig repo unless prefixed otherwise.

---

## 1. Modules exposed by build.zig + vendored-copy check

`build.zig` exposes these public modules via `b.addModule` (build.zig:23–155):

| Module name | Root file | Depends on |
|---|---|---|
| `provider` | src/provider/root.zig | — |
| `provider_utils` | src/provider_utils/root.zig | provider |
| `ai` | src/ai/root.zig | provider, provider_utils, openrouter, `ai_build_options` |
| `otel` | src/otel/root.zig | provider, provider_utils, ai |
| `openai_compatible` | src/openai_compatible/root.zig | provider, provider_utils |
| `openrouter` | src/openrouter/root.zig | provider, provider_utils, openai_compatible |
| `xai` | src/xai/root.zig | provider, provider_utils, openai_compatible |
| `anthropic` | src/anthropic/root.zig | provider, provider_utils |
| `openai` | src/openai/root.zig | provider, provider_utils |
| `google` | src/google/root.zig | provider, provider_utils |
| `mcp` | src/mcp/root.zig | provider, provider_utils, ai |
| `ffi` | src/ffi/root.zig | (C ABI; irrelevant to pi.zig) |

pi.zig's build.zig will do `ai_dep.module("ai")`, `.module("provider")`, `.module("provider_utils")`, plus one module per provider used (`anthropic`, `openai`, `openai_compatible`, `openrouter`, `google`, `xai`, `mcp`). Pattern shown in docs/book/src/getting-started.md:50–83.

Build option that matters: `-Ddefault-openrouter` (bool, default **true**, build.zig:12–16) compiles in the OpenRouter-backed resolver for bare string model ids. pi.zig can pass `-Ddefault-openrouter=false` through `b.dependency("ai_zig", .{ .@"default-openrouter" = false })`-style option forwarding if it wants only explicit provider construction. NOTE: the option is declared with `b.option` in ai.zig's own build; whether it's forwarded as a dependency option should be verified at integration time (it is read via `b.option`, so `b.dependency(..., .{ .@"default-openrouter" = false })` is the mechanism).

**Vendored copy check**: `/home/autark/src/zig/pi.zig/zig-pkg/zig_ai-0.1.0-0Q8L0BRHNgBeHLmVNmjZ0la63WPGiysWOhvNQ2S5_pMF` — `diff -rq` of `src/`, `build.zig`, and `build.zig.zon` against the ai.zig repo shows **zero differences**. The vendored package is exactly repo master (which is the v0.1.0 release state; repo working tree is clean except an untracked CLAUDE.md). No drift.

---

## 2. Exact call surface

### 2.1 generateText / streamText

```zig
// src/ai/generate_text.zig:344
pub fn generateText(io: std.Io, gpa: Allocator, options: GenerateTextOptions)
    provider.CallError!GenerateTextResult
// src/ai/stream_text.zig:367
pub fn streamText(io: std.Io, gpa: Allocator, options: StreamTextOptions)
    !StreamTextResult
```

`provider.CallError = provider.errors.Error || std.Io.Cancelable || std.mem.Allocator.Error` (src/provider/language_model.zig:8). The 36-name `provider.Error` set is at src/provider/errors.zig:7–44 (`APICallError`, `InvalidPromptError`, `NoSuchModelError`, `InvalidToolInputError`, `NoObjectGeneratedError`, `RetryError`, `LoadAPIKeyError`, `InvalidToolApprovalError`, `InvalidToolApprovalSignatureError`, `ToolCallNotFoundForApprovalError`, `TypeValidationError`, `UnsupportedFunctionalityError`, `DownloadError`, …).

**GenerateTextOptions** (src/ai/generate_text.zig:216–251), all fields:

```zig
pub const GenerateTextOptions = struct {
    model: registry.LanguageModelRef,                    // union(enum){ id: []const u8, model: provider.LanguageModel }
    instructions: ?prompt_api.Instructions = null,        // union(enum){ text, message: SystemModelMessage, messages: []const SystemModelMessage }
    prompt: ?prompt_api.PromptValue = null,               // union(enum){ text: []const u8, messages: []const ModelMessage }
    messages: ?[]const message.ModelMessage = null,       // prompt XOR messages enforced
    allow_system_in_messages: bool = false,
    tools: []const tool_api.NamedTool = &.{},
    tool_choice: ?prompt_api.ToolChoice = null,            // union(enum){ auto, none, required, named: []const u8 }
    active_tools: ?[]const []const u8 = null,              // filter without redefining tools
    tool_order: ?[]const []const u8 = null,                // provider presentation order
    stop_when: []const StopCondition = &.{},               // empty ⇒ single step (isStopConditionMet: steps.len == 1, generate_text.zig:1692)
    prepare_step: ?PrepareStep = null,
    repair_tool_call: ?RepairToolCall = null,
    refine_tool_input: ?[]const RefineToolInput = null,
    max_output_tokens: ?f64 = null,   temperature: ?f64 = null,
    top_p: ?f64 = null,               top_k: ?f64 = null,
    presence_penalty: ?f64 = null,    frequency_penalty: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?f64 = null,
    reasoning: ?provider.ReasoningEffort = null,           // enum { provider_default, none, minimal, low, medium, high, xhigh }
    headers: ?provider.Headers = null,                     // []const Header{name,value}
    provider_options: ?provider.ProviderOptions = null,    // = std.json.Value, namespaced per provider
    max_retries: u32 = 2,                                  // model-call retries only, 2000 ms initial delay, doubling
    timeout: ?TimeoutConfiguration = null,
    tools_context: ?std.json.Value = null,                 // per-tool context, keyed by tool name
    runtime_context: ?std.json.Value = null,
    output: ?Output = null,                                // structured output spec (ai.object/array/choice/json/text)
    callbacks: Callbacks = .{},
    telemetry: telemetry.TelemetryOptions = .{},
    tool_approval_secret: ?[]const u8 = null,              // HMAC-SHA256 signing of approval requests
    diag: ?*provider.Diagnostics = null,
};
```

**StreamTextOptions** (src/ai/stream_text.zig:75–115) = all of the above **plus**:

```zig
    transforms: []const StreamTransform = &.{},            // e.g. ai.smoothStream(.{ .delay_ms = 10, .chunking = .word })
    on_chunk: ?Callback(ChunkEvent) = null,                // ChunkEvent = { chunk: *const TextStreamPart }; awaited ⇒ backpressures provider
    on_error: ?Callback(StreamErrorEvent) = null,          // { call_id, stream_error: {error_value: json, error_code: ?anyerror} }
    on_abort: ?Callback(events.AbortEvent) = null,
    include_raw_chunks: bool = false,                      // emits .raw parts
```

**Timeouts** (src/ai/generate_text.zig:36–86):

```zig
pub const TimeoutConfiguration = union(enum) {
    total_ms: u64,
    granular: struct {
        total_ms: ?u64 = null, step_ms: ?u64 = null,
        chunk_ms: ?u64 = null,             // max gap between stream parts (streamText only)
        tool_ms: ?u64 = null,
        tools: []const ToolTimeout = &.{}, // ToolTimeout = { name, ms } per-tool override
    },
};
```
Total timeout is enforced by racing the operation against a sleep via `std.Io.Select` (generate_text.zig:1841–1878); on expiry the op is canceled and reported as `error.Canceled` with an `on_abort` reason of `"timeout"`.

**Stop conditions** (generate_text.zig:88–142): `StopCondition = { ctx: ?*const anyopaque, check_fn: fn(ctx, io, steps: []const StepResult) CallError!bool }`. Factories: `ai.stepCount(n)`, `ai.hasToolCall(comptime names)`, `ai.loopFinished()` (never stops early — runs until no tool calls). Conditions are evaluated concurrently after each step.

**prepare_step** (generate_text.zig:144–186): hook `fn(ctx, io, arena, *const PrepareStepOptions) CallError!?PrepareStepResult`. `PrepareStepOptions` gives `steps`, `step_number`, resolved `model`, current+initial `instructions`/`messages`, `response_messages`, `tools_context`, `runtime_context`. `PrepareStepResult` sparse-overrides: `model` (LanguageModelRef), `tool_choice`, `active_tools`, `tool_order`, `instructions`, **`messages`** (deep-cloned into the call arena when returned — stream_text.zig:698), `tools_context`, `runtime_context`, `provider_options`. **This is the only built-in between-step message rewrite hook — it is pi.zig's mid-run steering/compaction attachment point.**

**Callbacks** (generate_text.zig:196–214) — `Callback(E) = { ctx: ?*anyopaque, callback: fn(ctx, *const E) anyerror!void }` over events in src/ai/events.zig: `on_start` (GenerateTextStartEvent), `on_step_start` (StepStartEvent: has `prompt_messages: provider.Prompt`, resolved tools, previous steps), `on_language_model_call_start/_end`, `on_tool_execution_start/_end` (ToolExecutionEndEvent has `tool_output: union{result: json, err: anyerror}` and `tool_execution_ms`), `on_step_end` (`*const StepResult`), `on_end` (EndEvent: text, content, usage, response_messages, steps), `on_error`, `on_abort`.

### 2.2 Results

**GenerateTextResult** (src/ai/generate_text_types.zig:296–406): owns `arena_state: std.heap.ArenaAllocator`; every returned slice is valid until `deinit()`. Fields/accessors: `steps: []const StepResult`, `total_usage`, `response_messages`, `initial_response_messages`, `all_content/files/sources/tool_calls/static.../dynamic.../tool_results/.../warnings`, `parsed_output: ?OutputValue`. Methods: `deinit()`, `finalStep()`, `content()`, `text()` (final step's concatenated text), `reasoningText()`, `reasoning()`, `files()`, `sources()`, `toolCalls()`, `toolResults()`, `finishReason()` (`provider.FinishReason = { unified: enum{stop,length,content_filter,tool_calls,error,other}, raw: ?[]const u8 }`), `usage()`, `warnings()`, `request()`, `response()`, `providerMetadata()`, `responseMessages()`, `output() provider.Error!OutputValue`.

**StepResult** (generate_text_types.zig:142–289): `call_id`, `step_number`, `model: ModelInfo{provider_name, model_id}`, `content: []const ContentPart` (authoritative), `finish_reason`, `usage: provider.Usage`, `performance: StepPerformance`, `warnings`, `request: RequestMetadata{body: ?json, messages: ?[]const ModelMessage}`, `response: ResponseMetadata{id, timestamp_ms, model_id, headers, body, messages}`, `provider_metadata`; derived accessors `text()`, `reasoningText()`, `toolCalls()`, `toolResults()`, `toolErrors()`, static/dynamic splits. `StepPerformance` (generate_text_types.zig:111–121): `effective_output_tokens_per_second`, `output_tokens_per_second`, `input_tokens_per_second`, `effective_total_tokens_per_second`, `step_time_ms`, `response_time_ms`, `tool_execution_ms: []const {tool_call_id, milliseconds}`, `time_to_first_output_ms`, `time_between_output_chunks_ms: ?ChunkTimingStats{min,p10,median,avg,p90,max}`.

`provider.Usage` (src/provider/language_model.zig:374–393): `input_tokens: {total, no_cache, cache_read, cache_write: ?u64}`, `output_tokens: {total, text, reasoning: ?u64}`, `raw: ?JsonValue` (raw provider usage object per step — OpenRouter cost lands here when `include_usage=true`; openai_compatible fills it, src/openai_compatible/chat_language_model.zig:1123–1146). Aggregated `total_usage` drops `raw` (`addUsage` sets `.raw = null`, generate_text_types.zig:413–428).

**StreamTextResult** (src/ai/stream_text.zig:204–355):

```zig
pub fn next(self: *StreamTextResult, io: std.Io) anyerror!?TextStreamPart   // sole pipeline driver
pub fn fullStream(self) FullStreamCursor           // independent replay cursor; .next(io) std.Io.Cancelable!?Part
pub fn textStream(self) TextStream                 // .next(io) Cancelable!?[]const u8 (text deltas only)
pub fn partialOutputStream(self) PartialOutputStream // .next(io) anyerror!?OutputValue; needs .deinit()
pub fn elementStream(self, diag) provider.Error!ElementOutputStream // array-output only
pub fn consumeStream(self, io) anyerror!void
// Promise-like accessors — all call consumeStream first (block to completion), then
// completion check re-raises the recorded failure:
text(io), reasoningText(io), steps(io), finalStep(io), finishReason(io), rawFinishReason(io),
totalUsage(io), usage(io), responseMessages(io), content(io), toolCalls(io), toolResults(io),
warnings(io), request(io), response(io), providerMetadata(io), output(io)
pub fn attachCleanup(self, cleanup: StreamCleanup)  // one owner-cleanup, runs at deinit
pub fn deinit(self: *StreamTextResult, io: std.Io) void   // NOTE: streaming deinit takes io
```

Semantics (docs/book/src/appendix/contracts.md:10–29): every public part is appended to a mutex-guarded Broadcast log in the result arena; retention is unbounded for the result lifetime (upstream tee semantics). Derived cursors replay the log and **block until the driver advances**; cursors may be read from other threads. In-stream provider failures are `.err` **parts** (data); only machinery/OOM failures come out of `next()` as Zig errors.

### 2.3 Stream part unions

**Public `ai.TextStreamPart`** — 26 tags (src/ai/stream/parts.zig:92–119), payloads:

| tag | payload |
|---|---|
| `text_start`/`text_end` | `TextBlockBoundary{ id, provider_metadata }` |
| `text_delta` | `TextDelta{ id, text, provider_metadata }` |
| `reasoning_start`/`reasoning_end` | `TextBlockBoundary` |
| `reasoning_delta` | `TextDelta` |
| `custom` | `Custom{ kind, provider_metadata }` |
| `tool_input_start` | `ToolInputStart{ id, tool_name, provider_metadata, tool_metadata, provider_executed, dynamic, title }` |
| `tool_input_delta` | `ToolInputDelta{ id, delta, provider_metadata }` |
| `tool_input_end` | `ToolInputEnd{ id, provider_metadata }` |
| `source` | `provider.Source` |
| `file` / `reasoning_file` | `provider.GeneratedFile` / `GeneratedReasoningFile` |
| `tool_call` | `TypedToolCall{ tool_call_id, tool_name, input: json, provider_executed, provider_metadata, tool_metadata, dynamic, invalid, err: ?ToolCallError }` |
| `tool_result` | `TypedToolResult{ tool_call_id, tool_name, input, output: json, provider_executed, …, preliminary }` |
| `tool_error` | `TypedToolError{ tool_call_id, tool_name, input, error_value: json, error_code: ?anyerror, … }` |
| `tool_output_denied` | `{ tool_call_id, tool_name, provider_executed, dynamic }` |
| `tool_approval_request` | `types.ToolApprovalRequest{ approval_id, tool_call: TypedToolCall, is_automatic, signature: ?[]const u8 }` |
| `tool_approval_response` | `types.ToolApprovalResponse{ approval_id, tool_call, approved, reason, provider_executed }` |
| `start_step` | `StartStep{ request: RequestMetadata, warnings }` |
| `finish_step` | `FinishStep{ response: ResponseMetadata, usage, performance: StepPerformance, finish_reason, raw_finish_reason, provider_metadata }` |
| `start` | `void` |
| `finish` | `Finish{ finish_reason, raw_finish_reason, total_usage }` |
| `abort` | `Abort{ reason: ?[]const u8 }` |
| `err` | `StreamError{ error_value: json, error_code: ?anyerror }` |
| `raw` | `std.json.Value` |

**Provider-level `provider.StreamPart`** — 21 tags (src/provider/language_model.zig:583–630): `text_start`, `text_delta`, `text_end`, `reasoning_start`, `reasoning_delta`, `reasoning_end`, `tool_input_start`, `tool_input_delta`, `tool_input_end`, `tool_approval_request`, `tool_call` (GeneratedToolCall — `input` is a **JSON string** here), `tool_result`, `custom`, `file`, `reasoning_file`, `source`, `stream_start`, `response_metadata`, `finish`, `raw`, `err`. Provider parts are borrow-until-next-`next()` (language_model.zig:667–688). pi.zig should live at the `ai` layer where parts are arena-retained.

### 2.4 ToolLoopAgent (src/ai/agent.zig)

```zig
pub const ToolLoopAgent = struct {
    settings: ToolLoopAgentSettings,
    pub fn init(settings: ToolLoopAgentSettings) ToolLoopAgent            // :224 — value type, no deinit
    pub fn asAgent(self: *ToolLoopAgent) Agent                            // :228 — type-erased vtable {generate_fn, stream_fn, id, tools, version="agent-v1"}
    pub fn generate(self, io, gpa, params: AgentCallParameters)
        provider.CallError!generate_text.GenerateTextResult               // :238
    pub fn stream(self, io, gpa, params: AgentCallParameters)
        anyerror!stream_text.StreamTextResult                             // :256 — attaches StreamResources cleanup; freed at result.deinit(io)
};
```

`ToolLoopAgentSettings` (agent.zig:182–219): everything from GenerateTextOptions minus prompt/messages/callbacks-shape, plus `id: ?[]const u8`, `stop_when: ?[]const StopCondition = null` (**null ⇒ default `stepCount(20)`**; explicit `&.{}` ⇒ single-step), `tool_approval: ?ToolApprovalConfiguration{secret}`, `callbacks: LifecycleCallbacks`, `call_options_schema: ?provider_utils.Schema` (validates per-call `options` JSON before prepare_call), `prepare_call: ?PrepareCall`, `diag`.

`AgentCallParameters` (agent.zig:78–85): `{ options: ?json, prompt: ?PromptValue, messages: ?[]const ModelMessage, timeout: ?TimeoutConfiguration, callbacks: LifecycleCallbacks, transforms: []const StreamTransform }`. Prompt XOR messages validated before model invocation (agent.zig:460–476).

`LifecycleCallbacks` (agent.zig:65–72): `on_start, on_step_start, on_tool_execution_start, on_tool_execution_end, on_step_end, on_end` — settings-level and call-level are merged, both fire, callback errors are swallowed. `PrepareCall` hook: `fn(ctx, io, arena, *const PrepareCallOptions, diag) CallError!?PrepareCallResult` — sparse override of every setting; returning `prompt` clears `messages` and vice versa (agent.zig:424–431). Agent requests append user-agent suffix `ai-sdk-zig-agent/tool-loop` (agent.zig:23, 360–364).

### 2.5 Tool definition (src/ai/tool.zig)

Tools are **runtime values** (no comptime struct-of-tools sugar — explicitly deferred, tool.zig:182–184):

```zig
pub const ToolSet = []const NamedTool;
pub const NamedTool = struct { name: []const u8, tool: Tool };
pub const Tool = struct {
    kind: ToolKind = .function,          // .function | .dynamic | .provider_defined | .provider_executed
    name: ?[]const u8 = null,
    description: ?Description = null,    // .text or .resolver (dynamic description fn(ctx, tool_context) ![]const u8)
    input_schema: provider_utils.Schema, // REQUIRED
    output_schema: ?Schema = null,
    context_schema: ?Schema = null,
    execute: ?ToolExecute = null,        // absent ⇒ call surfaces but is not executed (client must handle)
    needs_approval: NeedsApproval = .no, // .no | .yes | .resolver{ fn(ctx, input, ToolExecutionOptions) !bool }
    on_input_start / on_input_delta / on_input_available: ?…Callback = null,
    to_model_output: ?ToModelOutput = null,  // custom conversion to message.ToolResultOutput
    metadata: ?json, provider_options: ?json, strict: ?bool,
    input_examples: ?[]const InputExample,
    provider_id: ?[]const u8, provider_args: ?json, supports_deferred_results: bool = false,
};
pub const ToolExecute = struct {
    ctx: ?*anyopaque = null,
    execute_fn: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,                       // for cooperative cancel: io.checkCancel()
        arena: std.mem.Allocator,         // per-tool isolated arena; output copied to call arena after join
        input: std.json.Value,            // schema-validated
        options: ToolExecutionOptions,    // { tool_call_id, messages: []const ModelMessage, context: ?json }
    ) anyerror!ToolOutput,
};
pub const ToolOutput = union(enum) { value: std.json.Value, stream: PreliminaryStream };
```

Schema: `provider_utils.schemaFromType(comptime T)` emits a camelCased draft-07-style document + generated validator (`additionalProperties:false` on objects; supports bool/num/str/slices/enums/structs/optionals/defaults). For hand-written JSON schema (what pi.zig will do for ported tools): `provider_utils.rawSchema(document_json: []const u8, validator: ?Validator)` (src/provider_utils/schema.zig:30–44). `Schema = { document: union{text: []const u8, value: json}, validator: ?Validator }`; a null validator means inputs are not client-validated.

**Dynamic tools** = `kind = .dynamic`; their calls/results are flagged `dynamic: true` in TypedToolCall/Result and split into `dynamicToolCalls()` accessors. MCP automatic-schema tools come in as dynamic.

Execution contract (contracts.md:31–51): blocking loop executes approved tools **concurrently** in isolated arenas via `std.Io.Group` (generate_text.zig:1418–1432), results assembled in tool-call order; streaming interleaves different tools' outputs in completion order after `model_call_end`. Tool throw ⇒ `tool_error` part fed back to the model, siblings unaffected. Retries never cover tool execution. Duplicate tool-call ids: last-write-wins (open item).

`repair_tool_call` hook (src/ai/tool_execution_common.zig:20–36): `fn(ctx, io, arena, *const RepairToolCallOptions{tool_call: GeneratedToolCall, tools, instructions, messages, err: ToolCallError}) anyerror!?GeneratedToolCall`. `refine_tool_input` (:38–47): per-tool-name input rewrite `fn(ctx, io, arena, input: json) !json`.

### 2.6 Approvals

Flow (tools.md:139–159, generate_text.zig:1464–1669):
1. A call whose `needs_approval` resolves true is **not executed**; the step records/streams a `tool_approval_request` part (`approval_id` freshly generated; `signature` present iff `tool_approval_secret` set). The loop **halts** with outputs < calls (contracts.md:46–48).
2. The app persists the assistant content (the `responseMessages()` already contain the assistant message with `tool_call` + `tool-approval-request` parts).
3. Next call: app appends a `ModelMessage{ .tool = .{ .content = &.{ .{ .tool_approval_response = .{ .approval_id = ..., .approved = true/false, .reason = ... } } } } }` as the **last message**, and passes the whole conversation as `messages`.
4. `replayInitialToolApprovals` runs **before step zero** of both generateText and streamText (generate_text.zig:318–342, stream_text.zig:601–621): it scans initial messages for calls + requests, matches responses in the trailing tool message, verifies HMAC signature when a secret is configured (mismatch ⇒ `error.InvalidToolApprovalSignatureError`), re-validates input schema and re-runs `.resolver` approval, executes approved calls, converts denials to `tool_result` with output `.execution_denied{ reason }`, and prepends the synthesized tool message to `current_messages` (also appears in `initial_response_messages`).
5. Unknown `approval_id` ⇒ `error.InvalidToolApprovalError`; request without a matching call ⇒ `error.ToolCallNotFoundForApprovalError`.

Signature binds approval_id + tool_call_id + tool_name + SHA-256 of canonical JSON input only — not run/user/model/expiry (contracts.md:75–87). In-process integrity only.

### 2.7 Cancellation / abort

There is **no cancel() method** on StreamTextResult or GenerateTextResult. The model is Zig 0.16 `std.Io` structured concurrency:

- The app runs the drive loop (or the whole call) inside `io.async(...)` and cancels the returned `std.Io.Future` from any thread: `future.cancel(io)`. This is exactly what the FFI does for `ai_stream_cancel` (src/ffi/stream.zig:99–103, 369–372): producer task pulls `result.next(io)` and forwards parts over an `std.Io.Queue`; cancel = `future.cancel(runtime.io())`.
- Inside the pipeline, `error.Canceled` from any pull is converted into a public `.abort` part (with `reason` when known, e.g. `"timeout"`) followed by stream finalization (stream_text.zig:484–497, 1006–1020); `on_abort` callbacks and telemetry fire. After abort, promise accessors re-raise `error.Canceled` (finalize sets completion failure, stream_text.zig:1027–1028).
- generateText total-timeout path: op raced against sleep; timeout ⇒ `error.Canceled` + AbortEvent reason "timeout"/"canceled" (generate_text.zig:373–396).
- Three layers (contracts.md:53–67): unblocking a waiting `next()` is sub-millisecond from any thread; in-flight I/O cancels at its next cancellation point; **tool code is cooperative only** — add `io.checkCancel()` inside long-running pi tools (bash, etc.). A canceled tool may still finish later; its effects can land after abort was reported.
- For pi.zig: the ESC-interrupt design should be: spawn stream-drive task with `io.async`, keep the future, `future.cancel(io)` on user interrupt, then `result.deinit(io)` after the driver returns. `deinit(io)` on an unconsumed stream is also legal (terminates + joins internally, stream_text.zig:538–548).

---

## 3. Message model, ownership, session pattern

**`ai.ModelMessage`** (src/ai/message.zig:416–429) — what pi.zig builds for multi-turn:

```zig
pub const ModelMessage = union(enum) {           // wire tag field "role"
    system:    SystemModelMessage,               // { content: []const u8, provider_options }
    user:      UserModelMessage,                 // { content: Content(UserContentPart), provider_options }
    assistant: AssistantModelMessage,            // { content: Content(AssistantContentPart), provider_options }
    tool:      ToolModelMessage,                 // { content: []const ToolContentPart, provider_options }
};
// Content(Part) = union(enum){ text: []const u8, parts: []const Part }
```

- `UserContentPart` = `text: TextPart{text, provider_options}` | `image: ImagePart` (deprecated, lowered with warning) | `file: FilePart{data: FilePartData, filename, media_type, provider_options}`; `FilePartData` = `data: DataContent{bytes|base64}` | `url` | `reference` | `text` | bare `string` (URL-probed else base64).
- `AssistantContentPart` = `text | custom | file | reasoning: ReasoningPart | reasoning_file | tool_call: ToolCallPart{tool_call_id, tool_name, input: json, provider_executed, provider_options} | tool_result: ToolResultPart | tool_approval_request: {approval_id, tool_call_id, is_automatic, signature}`.
- `ToolContentPart` = `tool_result: ToolResultPart{tool_call_id, tool_name, output: ToolResultOutput, provider_options}` | `tool_approval_response: {approval_id, approved, reason, provider_executed}`.
- `ToolResultOutput` = `text{value} | json{value} | execution_denied{reason} | error_text{value} | error_json{value} | content{value: []const ToolResultContentPart}` (11-variant content sub-union incl. text/file-data/file-url/image-data/…). Wire tags at message.zig:285–293.

**Canonical serialization exists and is the persistence mechanism**: every message type carries `wire_tags` and round-trips through `provider.wire.stringifyAlloc` / `provider.wire.parse` — the JSON uses upstream field names (`"role":"user"`, `"type":"tool-result"`, `"type":"tool-approval-response"`, camelCase fields). `message.cloneModelMessages(arena, msgs)` (message.zig:434–438) deep-clones **through this codec** — so pi.zig gets turn serialization for free by calling `provider.wire.stringifyAlloc(alloc, []const ModelMessage)` for its session file and `provider.wire.parse([]const ModelMessage, arena, value)` to load.

**Ownership rules (critical):**
- Options are **borrowed** for the duration of the call. streamText dupes `tools`, `stop_when`, `transforms` slices into its core arena (stream_text.zig:391–393) but **`messages`/`prompt` contents are borrowed** — the caller's message storage must outlive the stream (standardizePrompt uses caller slices directly, prompt.zig:47–54). Tool storage (NamedTool array + everything its fields point to) must outlive the agent and any active stream.
- Results own an arena; `responseMessages()`, `steps()`, everything — all die at `result.deinit()` / `deinit(io)`.
- **Long-lived session pattern** (what pi.zig must build): keep a session arena; per turn: (1) append user `ModelMessage` (session-owned), (2) run `agent.stream(io, gpa, .{ .messages = session.items })`, (3) after finish, `const rm = try result.responseMessages(io);` then `const owned = try message.cloneModelMessages(session_arena, rm);` append `owned` to the session list, (4) `result.deinit(io)`. ai.zig gives you: response-message construction (assistant + tool messages in correct order, incl. approvals; src/ai/response_messages.zig), deep clone, wire serialization. The app owns: the growing message list, its arena, and any pruning/compaction.
- `instructions` carries the system prompt separately from `messages` (system messages inside `messages` are rejected unless `allow_system_in_messages = true`, prompt.zig:59–68).

---

## 4. Providers

All providers require a transport: `var transport = provider_utils.HttpClientTransport.init(gpa, io); defer transport.deinit();` then `.transport()`. **No provider reads the process environment implicitly** — auth comes from explicit `api_key` or an injected `provider_utils.EnvLookup.fromMap(init.environ_map)` (docs/providers/index.md:26–47). Explicit settings win; API keys are resolved at call time (allows rotation).

### 4.1 Anthropic (`anthropic` module) — pi.zig's primary provider

```zig
pub fn createAnthropic(settings: Settings) error{InvalidArgumentError}!Anthropic  // src/anthropic/root.zig:73
// Settings (src/anthropic/config.zig:20–28):
//   base_url: ?[]const u8 = null,       // default https://api.anthropic.com/v1 (normalized, /v1 appended)
//   api_key: ?[]const u8 = null,        // XOR with auth_token; env: ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL
//   auth_token: ?[]const u8 = null,     // bearer-token alternative
//   env: provider_utils.EnvLookup = .empty,
//   headers: HeaderSource = .{ .static = &.{} },   // static slice or dynamic resolver
//   transport: provider_utils.HttpTransport,       // required
//   provider_name: []const u8 = "anthropic.messages",
var model = try factory.messages("claude-...", diag);   // .chat / .languageModel are aliases → AnthropicLanguageModel
const lm = model.languageModel();                        // provider.LanguageModel; NOTE: model must be `var` and outlive use
```

Provider options, namespace `"anthropic"` (or the custom provider_name prefix), src/anthropic/options.zig:18–35 — camelCase JSON keys:
`sendReasoning: ?bool`, `structuredOutputMode: ?enum{outputFormat,jsonTool,auto}`, `thinking: ?{ type: enum{adaptive,enabled,disabled}, budgetTokens: ?u64, display: ?enum{omitted,summarized} }`, `disableParallelToolUse: ?bool`, `cacheControl: ?{ type: enum{ephemeral}, ttl: ?enum{"5m","1h"} }`, `metadata.userId`, `mcpServers`, `container`, `anthropicBeta: ?[]const []const u8`, `toolStreaming: ?bool`, `effort: ?enum{low,medium,high,xhigh,max}`, `taskBudget`, `speed: ?enum{fast,standard}`, `inferenceGeo: ?enum{us,global}`, `fallbacks`, `contextManagement`.
- Thinking: top-level `reasoning: provider.ReasoningEffort` maps to adaptive thinking for capable families or a token budget for older ones (docs/providers/anthropic.md:41–44); explicit control via `providerOptions.anthropic.thinking`.
- **Prompt caching**: per-message/per-part `provider_options = {"anthropic": {"cacheControl": {"type":"ephemeral"}}}` on ModelMessage/parts; accepts `cacheControl` or `cache_control` key (src/anthropic/prompt.zig:644–646); max 4 breakpoints, excess ⇒ warning and drop (prompt.zig:32–43).
- Capability table `anthropic.getModelCapabilities(model_id)` (src/anthropic/capabilities.zig:3–86): `{ max_output_tokens, supports_structured_output, supports_adaptive_thinking, rejects_sampling_parameters, supports_xhigh_effort, is_known_model }` — substring-matched families up to claude-fable-5/sonnet-5 (128k out). **No context-window sizes, no pricing.**

### 4.2 OpenAI (`openai`)

```zig
var factory = openai.createOpenAi(.{ .allocator = gpa, .api_key = key, .transport = t });  // root.zig:199, infallible
var responses = try factory.responses("gpt-...", diag);   // ResponsesLanguageModel; .languageModel() alias → responses
var chat = try factory.chat("gpt-...", diag);             // ChatLanguageModel (/chat/completions)
```
Settings (src/openai/config.zig:23–34): `allocator` (required), `base_url`, `api_key` (`OPENAI_API_KEY`/`OPENAI_BASE_URL` via env), `organization`, `project`, `env`, `headers`, `transport`, `websocket_factory`, `name = "openai"`. Provider options namespace `"openai"` (src/openai/options.zig): `reasoningEffort` ∈ {"none","minimal","low","medium","high","xhigh","max"}, `reasoningSummary` (Responses), `serviceTier` ∈ {auto,flex,priority,default}, `textVerbosity` ∈ {low,medium,high}, logprobs, strictJsonSchema (default true), etc. Unsupported combos are stripped with typed warnings.

### 4.3 OpenRouter (`openrouter`)

```zig
var router = openrouter.createOpenRouter(.{ .api_key = key, .transport = t,
    .http_referer = "...", .x_title = "...", .include_usage = true });   // root.zig:76, infallible
var chat = try router.chatModel("vendor/model", diag);   // openai_compatible.ChatLanguageModel; ids passed through verbatim
```
Settings (src/openrouter/root.zig:8–16): `base_url` (default `https://openrouter.ai/api/v1`, env `OPENROUTER_BASE_URL`), `api_key` (env `OPENROUTER_API_KEY`), `env`, `transport`, `http_referer`, `x_title`, `include_usage: bool = false` (streams usage; raw usage object incl. OpenRouter's cost accounting surfaces in per-step `usage.raw`). Note `chatModel` takes `self: *OpenRouter` (mutable pointer — router must be `var`). Provider name `"openrouter"`; structured outputs advertised.

### 4.4 Google (`google`)

```zig
const factory = google.createGoogleGenerativeAi(.{ .allocator = gpa, .api_key = key, .transport = t }); // root.zig:126
var gemini = try factory.chat("gemini-2.5-flash", diag);   // .languageModel alias; .embedding/.embeddingModel for embeddings
```
Settings (src/google/config.zig:24–32): `allocator`, `base_url` (default `https://generativelanguage.googleapis.com/v1beta`, **no env lookup for base URL**), `api_key` (env `GOOGLE_GENERATIVE_AI_API_KEY` then `GOOGLE_API_KEY`), `env`, `headers`, `transport`, `name = "google.generative-ai"`. Auth header `x-goog-api-key`. Native generateContent/SSE; provider options under `"google"` namespace (thinking, safety, structuredOutputs toggle, etc.).

### 4.5 xAI (`xai`)

```zig
var factory = xai.createXai(.{ .allocator = gpa, .api_key = key, .transport = t });  // root.zig:131
var chat = try factory.chatModel("grok-4", diag);   // openai_compatible.ChatLanguageModel; .languageModel alias
```
Settings (src/xai/root.zig:13–20): `allocator`, `base_url` (default `https://api.x.ai/v1`, env `XAI_BASE_URL`), `api_key` (env `XAI_API_KEY`), `env`, `headers`, `transport`. Provider name `"xai.chat"`. Also `videoModel` (deferred-job video; irrelevant to pi core).

### 4.6 openai_compatible (generic endpoints — Groq/DeepSeek/Mistral/Together/Fireworks presets)

`createOpenAiCompatible(Settings)` with (src/openai_compatible/config.zig:46–65): `provider_name` (required), `base_url` (required, always explicit), `api_key`, `api_key_env_var` (default derives `<PROVIDER_NAME>_API_KEY`), `env`, `default_headers`, `headers`, `user_agent_suffix`, `query_params`, `transport`, `include_usage`, `supports_structured_outputs`, `strict_json_schema_default = true`, embedding limits, `error_hooks`. This is pi.zig's path for arbitrary user-configured OpenAI-compatible endpoints.

### 4.7 Model refs / registry / defaults

`GenerateTextOptions.model` takes `.{ .model = someLanguageModel }` (explicit, recommended) or `.{ .id = "string" }`. Bare ids resolve through: installed `ai.setDefaultProvider(provider)`, else the compiled-in OpenRouter default which requires `ai.setDefaultRuntime(gpa, io)` + `ai.setDefaultEnv(env)` (or `ai.useOpenRouterDefault(gpa, io, env)`) and `OPENROUTER_API_KEY`; otherwise `LoadAPIKeyError` with no request (src/ai/registry.zig:439–492; docs/providers/openrouter.md:29–47). `ai.createProviderRegistry` / `ai.customProvider` compose multiple providers under `"prefix:model"`-style ids with a configurable separator. For pi.zig (multiple providers, model switching at runtime): either construct provider factories per configured provider and hand `LanguageModel` values around, or build one `ProviderRegistry`. Every completed step records resolved `provider_name`/`model_id` in `StepResult.model`.

### 4.8 Diagnostics & retries

`provider.Diagnostics.init(gpa)` / `.deinit()`; pass `&diag` as `options.diag`; on error check `diag.available`, `diag.payload` (tagged union: url/status/body/parameter/model id/offending JSON/finish reason/retry log), `diag.message(arena)` for formatted text (src/provider/errors.zig:329–375). Model calls retry ×2 by default (HTTP 408/409/429/5xx), first non-retryable error returned unchanged, exhaustion ⇒ `RetryError`; cancellation never wrapped (core-concepts.md:144–154).

---

## 5. MCP client (`mcp` module)

```zig
var client = try mcp.createMcpClient(gpa, io, .{ .transport = ..., .max_retries = 0,
    .client_name = "ai-sdk-zig-mcp-client", .version = "1.0.0", .capabilities = null,
    .on_uncaught_error = null });          // src/mcp/client.zig:576 → *Client; performs initialize handshake
defer client.deinit(io);
```

Transports (`Options.transport` union): 
- `.stdio = StdioTransportConfig{ command, args, parent_environ: ?*const std.process.Environ.Map, env: []const EnvEntry, cwd, stderr: StderrBehavior = .inherit, close_grace_ms = 1000 }` (src/mcp/stdio_transport.zig:17–28) — newline-delimited JSON-RPC over a child process; `parent_environ = null` means **no** inherited environment (explicit whitelist model).
- `.sse = SseTransportConfig` — legacy SSE (requires real concurrency).
- `.http = HttpTransportConfig{ url, headers, transport: ?HttpTransport, auth_hook: ?AuthHook (called once after a 401), initial_session_id, initial_protocol_version, on_session_changed, on_session_expired, terminate_session_on_close = true }` (src/mcp/http_transport.zig:22–32) — streamable HTTP with `Mcp-Session-Id`, `Last-Event-ID` resume, bounded backoff.

Client APIs (all `anyerror!`, results parsed into `arena`): `listTools(io, arena, cursor)` (auto-paginates), `callTool(io, arena, name, arguments: ?json) !types.CallToolResult` (client.zig:193–243, optional retry), `listResources`, `readResource(uri)`, `listResourceTemplates`, `listPrompts`, `getPrompt(name, args)`, raw requests, elicitation handler hook.

**Tool bridging**: `client.tools(io, arena, .{ .schemas = .automatic | .{ .explicit = []ExplicitSchema{name, input_schema, output_schema} } }) ![]const ai.NamedTool` (client.zig:245–261) — returns NamedTool values whose execute closures call the server via `tools/call`. Automatic schemas ⇒ dynamic tools normalized with `additionalProperties:false`; explicit schemas ⇒ named tools with optional structured-output validation; `isError` results become model-visible tool errors (src/mcp/tools.zig:47–82). The returned tools plug directly into `GenerateTextOptions.tools` / `ToolLoopAgentSettings.tools`. Pending requests complete as connection-closed on teardown.

---

## 6. Frank gap list vs a Pi-style coding agent

What ai.zig **provides** vs what pi.zig's app layer **must build**:

| Need | Status in ai.zig | pi.zig must build |
|---|---|---|
| **Mid-run steering / user message injection** | Partial. `prepare_step` can replace the *entire* `messages` slice between model steps (PrepareStepResult.messages, deep-cloned) and swap model/tools/instructions. There is **no queue-a-message-into-a-running-turn API**, no "interrupt after current step and continue" primitive. Streaming loop cannot be paused. | A steering layer: either (a) cancel the in-flight stream (`future.cancel`), splice pending user input into the session, restart; or (b) a `prepare_step` hook that drains an app-side injection queue between steps. Pi's "steering while tool runs" semantics need (a) plus tool-level cooperative checks. |
| **Turn persistence / serialization** | The canonical wire codec is a real serializer: `provider.wire.stringifyAlloc` / `provider.wire.parse` round-trip `[]const ModelMessage` with upstream JSON tags, and `message.cloneModelMessages` deep-clones. Result exposes ordered `responseMessages()`. | Session file format, versioning, the append-only session store, and the clone-into-session-arena discipline (results die at deinit). Nothing persists StepResult/usage — serialize those separately if needed. |
| **Compaction** | Nothing. No summarization, no message pruning, no auto-compaction on context overflow. `finish_reason.unified == .length` and anthropic's `model_context_window_exceeded` → `.length` mapping (anthropic/language_model.zig:1556) are the only overflow signals. | Entire compaction subsystem: token budgeting, summarize-and-replace, tool-result truncation. Can be wired in via `prepare_step` (replace messages) or before-call in the session layer. |
| **Token counting** | None. No tokenizer, no countTokens anywhere in src/. Usage is only reported *after* each step (`StepResult.usage`, optional fields). | Estimation (bytes/4 heuristics or a vendored tokenizer) for pre-flight budgeting; post-hoc tracking from per-step `provider.Usage` (incl. cache_read/cache_write — good enough for cost display per turn). |
| **Model catalog: context windows, pricing** | None. Model ids are passed through unvalidated (providers/index.md:5–7). Only `anthropic.getModelCapabilities` exists (max output tokens + feature flags; no context window, no prices). `usage.raw` retains raw provider usage per step (OpenRouter cost fields land there when `include_usage=true`). | Full model catalog (context window, max output, pricing, capability flags) — port Pi's models.json/models.dev approach. Cost computation from Usage × catalog prices. |
| **Cancellation UX** | Solid primitive: `io.async` + `Future.cancel` from any thread; `.abort` stream part; cooperative tool cancel. | The interrupt plumbing (ESC → cancel → partial-turn persistence: note the Broadcast log/steps are lost at deinit unless copied first — pi must snapshot text/tool state from consumed parts, not from the result, when aborting mid-step). |
| **Approvals UI loop** | Complete data model: `tool_approval_request` part mid-stream, halt semantics, next-turn `tool_approval_response` replay, deny⇒execution_denied. | The interactive gate itself (Pi asks synchronously *during* the run). ai.zig's model is turn-based: request ends the turn, response starts the next. To keep Pi's in-run modal UX, pi.zig can implement approval *inside* tool `execute` (block on a UI channel, honoring `io.checkCancel`) instead of `needs_approval`, or accept the two-turn shape. |
| **Sub-agents** | `ToolLoopAgent` is reusable and cheap (value type); type-erased `Agent` vtable exists. No task/sub-agent orchestration. | Pi's subagent tool: spawn nested agent calls with own tools/session; straightforward on top of `ToolLoopAgent.generate` in a tool's execute. |
| **Provider streaming quirks** | Handled: SSE decode, anthropic 200-with-error peek, retry engine, thinking/cache/reasoning mapping, `extractReasoningMiddleware`/`extractJsonMiddleware`/`simulateStreamingMiddleware` (src/ai/middleware.zig) for tag-based reasoning models. | Nothing beyond configuration. |
| **UI message stream** | `ai.ui` has UIMessage/UIMessageChunk/Chat and `convertToModelMessages` (Vercel-shaped, web-oriented). | Pi's TUI transcript should consume `TextStreamPart` directly (per the AgentCommand/AgentEvent mailbox decision); the ui module is not a fit for ZigZag rendering but its reducer may inform TranscriptView design. |
| **Download URL allow/deny policy** | Built in for provider media downloads: http/https only, string-level internal-address deny list, ≤10 redirect hops re-validated, 2 GiB cap; no DNS resolution at that layer (hostname-vs-resolved-address gap is documented open, contracts.md:89–100). | Pi's own fetch/web tools need their own policy; don't assume ai.zig's downloader covers app tools. |
| **Telemetry/OTel** | `telemetry.TelemetryOptions` per call, process-global registration, `otel` module exporter. | Optional; Pi session logs can hang off lifecycle callbacks instead. |

**Other integration facts worth pinning:**
- Threading model: one `std.Io` (e.g. `std.Io.Threaded` from `std.process.Init`) shared by transport, models, calls, and tools. Tool concurrency and timeouts degrade gracefully (with a warning) when the Io has no real concurrency; the WebSocket/realtime path is the only hard-concurrency surface.
- `max_output_tokens`/`seed` are `?f64` at the ai layer and validated to integers (`prepareLanguageModelCallOptions`, prompt.zig:107–141) — InvalidArgumentError on non-integers.
- streaming result is lazy: nothing happens until the first `next(io)`/accessor; `start` part is synthesized first, prompt standardization errors surface as `.err` parts (stream_text.zig:613–626).
- `ToolLoopAgent` default `stop_when = stepCount(20)`; bare `generateText` default is single-step. For a coding agent loop pi.zig will likely pass `stop_when = &.{ai.loopFinished()}`-style unbounded-until-no-tool-calls, or a high stepCount, plus its own turn limits.
- Everything the model returned in a step is in `StepResult.content` in order — pi's transcript can be rebuilt from steps for the blocking path, or from the part stream for live rendering; both are the same log.

