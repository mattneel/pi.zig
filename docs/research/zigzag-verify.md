# ZigZag vendored-copy verification report

**Tree verified:** `/home/autark/src/zig/pi.zig/zig-pkg/zigzag-0.1.2-YXwYS_kJEgA3GRXhR4qLp6PfG0-RKpyQq-DxJLLqlF0a` (package `zigzag` v0.1.2, fingerprint `0xdffe16194b187c61`, pinned commit 226dd3f per directory hash). All `path:line` citations below are relative to this root. Total source: 33,032 lines across 96 `.zig` files (`wc -l`).

**Ship manifest note (affects several claims):** `build.zig.zon` `.paths` includes only `build.zig`, `build.zig.zon`, `src`, `README.md`, `LICENSE` (build.zig.zon:6-12). The `examples/` (44 examples) and `tests/` (23 test files) directories referenced by `build.zig:15-60` and `build.zig:92-116` are **not present** in the vendored tree (verified by `find` — only LICENSE, README.md, build.zig, build.zig.zon, src/). Consuming the module via `b.dependency(...).module("zigzag")` works (those steps are never executed by a consumer), but running `zig build` or `zig build test` *inside* the vendored directory would fail on the missing files. The external test suite is therefore not available locally; only the 118 inline `test` blocks inside `src/` are.

---

## Claim 1 — Zig 0.16 + std.Io into Program and Context: **CONFIRMED**

- `minimum_zig_version = "0.16.0"` — build.zig.zon:5.
- `Program(Model)` stores `io: std.Io` — src/core/program.zig:50; `init(allocator, io, environ_map)` — program.zig:87-93; `initWithOptions` same — program.zig:96-101.
- `Context` stores `io: std.Io` ("Asynchronous I/O facilities") — src/core/context.zig:25-26; `Context.init(allocator, persistent_allocator, io, environment)` — context.zig:80-85.
- 0.16-only idioms throughout: `std.Io.Clock.Timestamp.now(io, .boot)` (program.zig:103, 219), `std.Io.File` (context.zig:364-367), `std.process.Environ.Map` (program.zig:90), `std.Io.Mutex` (src/core/log.zig:15), `std.Io.Writer.Allocating` (components, e.g. virtual_list.zig:150), a comment noting `posix.isatty` "was removed in Zig 0.16" (src/terminal/platform/posix.zig:42-44), and `std.process.run(allocator, io, ...)` (terminal.zig:989-993).
- **Beyond the claim:** `Program.init` requires a third argument, `environ_map: *const std.process.Environ.Map` (program.zig:90), converted via `Environment.fromEnvMap` (src/core/environment.zig:24). The README quick start uses `pub fn main(init: std.process.Init)` and passes `init.gpa, init.io, init.environ_map` (src/root.zig:41-45). Any port scaffolding must thread the environ map through.

## Claim 2 — Elm-style MUV, no external deps: **CONFIRMED**

- `Program(Model)` comptime-enforces `Msg`, `init`, `update`, `view` declarations — program.zig:30-43. Optional `Model.deinit` honored — program.zig:147-149.
- Model contract: `init(*Model, *Context) Cmd(Msg)`, `update(*Model, Msg, *Context) Cmd(Msg)`, `view(*const Model, *const Context) []const u8` — root.zig:19-39 (doc example) and dispatch sites program.zig:230, 360, 828.
- `view` returns a plain `[]const u8` string (whole frame); there is no widget tree or cell-buffer retained-mode API in the runtime loop.
- Zero dependencies: `.dependencies = .{}` — build.zig.zon:13; README "Zero Dependencies" — README.md:29.

## Claim 3 — start() + tick() custom loop, plus run(): **CONFIRMED**

- `run()` = `try self.start(); while (self.running) try self.tick();` — program.zig:159-166.
- `start()` initializes logger, terminal, size, unicode strategy, clocks, frame arena, calls `model.init` and processes its command, sets `running = true` — program.zig:180-234. Doc comment explicitly describes the custom-loop pattern with `isRunning()` — program.zig:168-179.
- `isRunning()` — program.zig:237-239; `tick()` (one frame: resize check → non-blocking input drain → one-shot/repeating timers → render → image flush → frame pacing) — program.zig:242-350; `quit()` — program.zig:882-884.
- Pacing detail: sleep happens at the **end** of `tick()` via absolute deadline `deadline.wait(self.io) catch unreachable` — program.zig:343-347; first tick skips pacing (program.zig:332); falling >4 frames behind rebases the anchor instead of burst-rendering — program.zig:336-341.

## Claim 4 — send() is synchronous, not a thread-safe mailbox: **CONFIRMED**

- `pub fn send(self: *Self, m: UserMsg) !void { const cmd = self.dispatchToModel(m); try self.processCommand(cmd); }` — program.zig:876-879. No queue, no mutex, no atomics anywhere in program.zig (grep for Mutex hits only log.zig and dev_console.zig).
- `dispatchToModel` invokes `self.model.update(msg, &self.context)` directly on the calling thread (applying the optional filter fn) — program.zig:353-361.
- `processCommand` recurses on the calling thread: `.msg` re-dispatches and recurses (program.zig:499-502); `.perform` invokes the function pointer inline, then recurses on its result (503-508); `.batch`/`.sequence` iterate recursively (489-498) — note batch and sequence are implemented identically (both just loop). Commands also touch the terminal directly (`.show_cursor` etc., 522-535), so calling `send` from a non-UI thread is a data race on both model state and terminal writer.

## Claim 5 — Ctrl+C intercepted pre-model; Ctrl+Z optional; no ctrl_c option: **CONFIRMED**

- `processKeyEvent`: on ctrl, `.char == 'c'` → `self.running = false; return null;` — the model never receives the key and no quit message is dispatched — program.zig:363-371.
- `'z'` gated on `self.options.suspend_enabled` → `performSuspend()` (terminal cleanup → raise SIGTSTP → re-setup → clock/pacing/timer rebase → forced re-render via `last_view_hash = 0` → optional `.resumed` message if the Msg union has that field) — program.zig:373-376, 425-473.
- `Options` (src/core/context.zig:344-383) contains `suspend_enabled: bool = true` (context.zig:381-382) and **no** ctrl_c-related field. Full Options field list: `fps`, `mouse`, `cursor`, `alt_screen`, `bracketed_paste`, `title`, `input`, `output`, `log_file`, `kitty_keyboard`, `osc52`, `unicode_width_strategy`, `suspend_enabled`.
- Related facts: raw mode sets `ISIG = false` (posix.zig:100), so Ctrl+C arrives only as bytes — once the hardcoded intercept is bypassed, the key is fully deliverable to the model. `Cmd.suspend_process` exists for programmatic suspend (src/core/command.zig:169-170; handler program.zig:509-511). Windows: `performSuspend` early-returns (program.zig:426).

## Claim 6 — AsyncRunner: raw threads + un-synchronized ArrayList: **CONFIRMED**

File: src/core/async_task.zig (claimed path exact).
- Results queue is `std.array_list.Managed(?Msg)` — async_task.zig:14; no mutex anywhere in the file (grep confirms; the only mutexes in the library are in log.zig and dev_console.zig).
- `spawn`/`spawnWithArg` start raw `std.Thread.spawn` workers — async_task.zig:36, 65-69; worker completion calls `pushResult` → `self.results.append(m) catch {}` — async_task.zig:92-94.
- UI thread `poll()` iterates `self.results.items` and `clearRetainingCapacity()` — async_task.zig:79-90.
- **This is a data race as written**: a worker append can reallocate/extend the backing array while the UI thread iterates or clears it, and two workers can append concurrently. The file's own doc comment "Thread-safe result queue" (async_task.zig:6-7) is wrong.
- Additional defects to know before porting/contributing: `poll()` allocates a fresh Managed list per call and returns `.items` that the runner never frees (async_task.zig:82-89); `SpawnContext`/`Closure` heap allocations are never destroyed after the task runs (async_task.zig:33-34, 62-63, 101-107); thread handles are discarded without join/detach (async_task.zig:36, 65); `spawn` returns id `0` as an untyped failure sentinel (async_task.zig:33-39); `next_id` increments unsynchronized (fine only if spawn is UI-thread-only).
- Contrast: `DevConsole` (src/core/dev_console.zig:17, 67, 197-198) is properly mutex-guarded (`std.Io.Mutex`, `lockUncancelable`) and is the in-tree template for correct cross-thread code.

## Claim 7 — Frame arena vs persistent allocator; 60fps default: **CONFIRMED**

- `Context.allocator` documented "temporary allocations (reset each frame)"; `Context.persistent_allocator` "not reset between frames" — context.zig:16-20.
- Program owns `arena: std.heap.ArenaAllocator` (program.zig:52, 102); `resetFrameAllocator` does `arena.reset(.retain_capacity)` and re-points `context.allocator` at the arena — program.zig:822-825; called at start (227) and at the top of every tick (251). `persistent_allocator` stays the caller's gpa (Context.init called with `(allocator, allocator, ...)` — program.zig:131; the comment at 129-130 explains why the arena allocator cannot be captured at init: `self` is returned by value and the pointer would dangle).
- Consequence: everything `view()` returns and everything parsed from input (`keyboard.parseAll(self.context.allocator, ...)` — program.zig:274) lives exactly one frame.
- `fps: u32 = 60` default — context.zig:345-346. Pacing: `min_frame_time_ns = ns_per_s / options.fps`, with `fps == 0` falling back to `16_666_666` ns (~60fps) — program.zig:327-330. **There is no uncapped mode**; fps=0 does not disable pacing.

## Claim 8 — Component inventory: **CONFIRMED (and larger than claimed)**

README claims "34+" (README.md:11); the components directory has **53 files**, all exported via `root.zig:149-237`. Everything in the claim list exists. Full inventory with size and maturity signal (inline test count in parens; 0 = none):

| Component | File (lines) | Notes |
|---|---|---|
| TextArea | components/text_area.zig (1057) | line storage = ArrayList of ArrayLists (text_area.zig:15), word wrap with wrapped-segment math, line numbers, char/line limits, unicode-width-aware cursor. **No undo/redo, no selection, no clipboard** (grep: zero hits). (0) |
| TextInput | components/text_input.zig (462) | placeholder, prompt, echo modes, validation fn, autocomplete suggestions (text_input.zig:36-40, 158). No history/undo. (0) |
| Viewport | components/viewport.zig (456) | y/x scroll, optional wrap, scrollbar, dupes content and splits lines on `setContent` (viewport.zig:74-87). (0) |
| Markdown | components/markdown.zig (350) | see claim 10. (0) |
| DiffView | components/diff_view.zig (285) | computes its own LCS line diff (diff_view.zig:88-91), unified + side-by-side, line numbers; **no word-level intra-line diff, no syntax coloring of content**; 42 `catch {}` swallows. (0) |
| CodeView | components/code_view.zig (255) | naive per-line tokenizer; `Language = {zig, python, javascript, go, rust, plain}` (code_view.zig:83-90); strings/comments/keywords/Zig builtins; multiline-comment flag threaded per render pass (code_view.zig:99, 128). Not a real lexer. (0) |
| CommandPalette | components/command_palette.zig (422) | fuzzy filter via core/fuzzy.zig, `setFromRegistry(ActionRegistry)` integration (command_palette.zig:161), handleKey/KeyResult protocol. (3) |
| Modal | components/modal.zig (761) | buttons + shortcuts, backdrop (solid/custom), padding, presets info/confirm/warning/err (modal.zig:190-238). (0) |
| Confirm | components/confirm.zig (154) | minimal yes/no. (0) |
| StatusBar | components/status_bar.zig (215) | left/center/right segments, separator. (3) |
| Tree | components/tree.zig (185) | addRoot/addChild/toggleNode + enumerator glyphs; **no built-in keyboard navigation/cursor** — minimal. (0) |
| SplitPane | components/split_pane.zig (246) | ratio, keyboard resize (`handleResize`), `compose(a,b)`. (5) |
| RichLog | components/rich_log.zig (422) | capacity ring, levels, search filter, scroll, appendFmt. (6) |
| List | components/list.zig (490) | items with title/description, fuzzy filtering, selection. (0) |
| Dropdown | components/dropdown.zig (719) | searchable, descriptions, open/close/toggle. (0) |
| VirtualList | components/virtual_list.zig (216) | see claim 9. `toggleSelection` is an explicit stub ("placeholder for signaling", virtual_list.zig:134-138). (0) |
| Spinner | components/spinner.zig (146) | frame sets (dots/line/...), fps, tick/update. (0) |
| Progress | components/progress.zig (264) | gradient/ascii/block modes, head char. (0) |
| Table | components/table.zig (469) | comptime `Table(num_cols)`, row selection, borders. (0) |

Also shipped (not in the claim's list): DataTable (530, 6 tests), SortableTable (321), TabGroup (1066), Tooltip (925), MenuBar (576), FocusGroup/focus (553, 9 tests), Canvas (484), BrailleCanvas (412, 7), Chart (758) + charting (253) + BarChart (289) + Sparkline (229) + Heatmap (250) + Gauge (249), Toast (444), Checkbox/CheckboxGroup (434), ContextMenu (392), FilePicker (422), Calendar (304), Form (299), Slider (291), RadioGroup (276), Stepper (254), Help (238), Paginator (226), Timer (223), Breadcrumb (223, 3), StyledList (169), Notification (139), Keybinding/KeyMap (114). Core extras: ScreenStack router with modal overlay + vtable screens (core/screen_stack.zig:35-77, 4 tests), SubProgram child-model embedding (core/sub_program.zig:13-80 — note it **drops** child `.msg`, `.perform`, `.batch`, `.sequence` commands in translation, sub_program.zig:60-77), ActionRegistry/Footer (core/action.zig, 8 tests), Tween/Easing animation (core/animation.zig), fuzzy matcher (core/fuzzy.zig, 6 tests), DevConsole (core/dev_console.zig, mutex-guarded, file/TCP sinks), hitbox mouse framework (input/hitbox.zig), flex layout engine (layout/flex.zig, 6 tests), layer compositing (layout/layer.zig), snapshot testing (testing/snapshot.zig — golden files, `ZIGZAG_UPDATE_SNAPSHOTS=1`, ANSI stripping; snapshot.zig:1-33).

## Claim 9 — VirtualList assumes 1 row per item: **CONFIRMED**

- Scroll state is item-indexed: `cursor: usize`, `offset: usize` ("first visible item index"), `viewport_height: u16` in rows — virtual_list.zig:16-20.
- `ensureVisible` does pure item arithmetic `offset + viewport_height` — virtual_list.zig:140-147; page up/down move by `viewport_height` items — virtual_list.zig:101-113.
- `view()` renders exactly one line per visible item (`\n` between items, loop `self.offset..end` where `end = min(offset+vh, total)`) — virtual_list.zig:160-191; the scrollbar column is emitted per item-row (182-190); `render_fn` returns a single string treated as one row (virtual_list.zig:28, 169-172).
- A multi-line `render_fn` result would silently break the viewport height, the scrollbar column, and scroll math. **Unsuitable for variable-height transcript blocks as-is.** No per-item height hook exists.

## Claim 10 — Markdown re-walks source per render; supported constructs: **CONFIRMED**

- `render(self, allocator, source)` is a stateless full pass: `splitScalar(source, '\n')` and a line loop with a local `in_code_block` flag — markdown.zig:129-268. No caching, no incremental parse, no AST. Each call re-processes the entire source. (Program-level mitigation is only the whole-frame output hash, program.zig:831-834 — the walk itself still happens every frame.)
- Supported: fenced code blocks (any line whose trimmed start is ``` ``` `` toggles; fence drawn as a box border capped at `min(width-2, 40)` wide; the info string/language tag is discarded; no syntax highlighting inside) — markdown.zig:148-180; horizontal rules from `---`/`***` lines (≥3 chars, spaces allowed) — 185-199; ATX headers `# `, `## `, `### ` **only** (`####`+ falls through to paragraph) — 202-219; single-level blockquote `> ` with a `│` gutter — 222-229; unordered lists `- `/`* ` with indent preserved and `•` bullet — 232-241; ordered lists (digit + `. ` found within the first 4 chars) — 244-255; inline `**bold**`, `*italic*`, `` `code` ``, `[text](url)` rendered as underlined text plus dim ` (url)` — renderInline, 273-342.
- Not supported: nested inline formatting (bold/italic content is styled raw, no recursion — 282-287), h4–h6, setext headers, tables, task lists, strikethrough, images, HTML, reference links, nested blockquotes/lists (indent is preserved but not semantically nested), soft wrapping to width (width is only used for fence/hr lengths). Rough edge: `self.width - 2` underflows `u16` if `width < 2` — markdown.zig:155, 165.

## Claim 11 — Custom I/O streams and image protocols: **CONFIRMED (with a caveat)**

- Custom streams: `Options.input/output: ?std.Io.File` — context.zig:363-367 → forwarded in `start()` (program.zig:195-196) → `terminal.Config.input/output` — terminal.zig:252-255 → used for the fds and raw-mode target — terminal.zig:286-296. Pipe-friendly: non-TTY input skips raw mode (posix.zig:70-74) and non-TTY size falls back to 80x24 (posix.zig:54-57). **Caveat:** these are `std.Io.File` handles, not generic reader/writer interfaces — tests need real fds (pipe/pty), not in-memory buffers. Snapshot testing (testing/snapshot.zig) is the intended render-level test path.
- Image protocols: all three present in src/terminal/terminal.zig — Kitty graphics (draw/transmit/place/delete: 620, 666, 709, 730; unicode placeholders, z-index, caching), iTerm2 inline (749, 780), Sixel (955 — native `.six` passthrough or **shelling out to `img2sixel`** via `std.process.run`, terminal.zig:967-1002). Auto-selection order Kitty > iTerm2 > Sixel (command.zig:19-28; terminal.zig:805-870). Capability detection from environment identity + live Kitty probe with multiplexer awareness (terminal.zig:1030-1060, referencing upstream issue #113). Command-level API: `Cmd.image_file/.image_data/.cache_image/.place_cached_image/.delete_image` (command.zig:184-200) handled in processCommand/flushPendingImage (program.zig:566-613, 617-718). Context exposes the full drawing API too (context.zig:233-340).

## Claim 12 — Overall quality/maturity assessment

Honest read: **an ambitious, fast-moving 0.1.x library — genuinely useful core, uneven depth, several sharp edges.**

Strengths:
- The core loop is thoughtfully engineered: boot-clock epochs so suspend doesn't distort elapsed time, absolute-deadline pacing with overrun rebase, careful suspend/resume timer re-anchoring — all with unusually good comments (program.zig:58-73, 326-349, 444-463).
- Real Unicode work: width strategy detection (mode 2027, kitty text sizing), a 677-line display-width table with 16 tests (unicode/display_width.zig), atomic global strategy (unicode.zig:15-17).
- Terminal layer is broad and modern: kitty keyboard protocol both enable (terminal.zig:346-348) and parse (CSI-u, keyboard.zig:155-156, 210), bracketed paste, OSC52 clipboard read+write, three image protocols with live capability probing, WASM + Windows + POSIX platform backends.
- 118 inline `test` blocks across 25 files, concentrated in infrastructure (display_width 16, terminal 9, focus 9, action 8, braille_canvas 7, fuzzy/flex/rich_log/data_table 6 each).

Weaknesses:
- **The external test suite and all 44 examples are not shipped** in the package (see manifest note). The vendored tree cannot run `zig build test` as-is.
- **Zero inline tests in the highest-risk code**: program.zig, context.zig, async_task.zig, and zero in most big components (text_area, text_input, viewport, markdown, virtual_list, diff_view, code_view, modal, list, dropdown, table, tree).
- AsyncRunner has a data race plus three distinct leaks (claim 6) despite claiming thread safety.
- Pervasive silent error swallowing in component `view()` paths — ~199 `catch {}`/`catch unreachable` sites overall; diff_view alone has 42 `catch {}`; on OOM views silently truncate.
- `catch unreachable` on the pacing wait (program.zig:347) and sleep (program.zig:819 — `sleepNs` appears to be dead code) — a failed wait crashes the app.
- Rendering is string-diff-by-hash only: `model.view()` is called **every frame** regardless of activity (program.zig:828), the whole frame is Wyhash-hashed (831), and on any change every line is rewritten (`cursor_home` + rewrite + EL per line, 838-866). A cell-based double buffer with per-cell `eql` exists (terminal/screen.zig:9-36) but the runtime loop never uses it — it's exported dead weight (root.zig:88).
- Stubs/dead code: `VirtualList.toggleSelection` is a no-op placeholder (virtual_list.zig:134-138); `message.SystemMsg.isQuit` compares a tagged union against a full union literal with `==` (message.zig:64-69), which is not a legal Zig comparison — it is never called anywhere, so it never gets analyzed; calling it would fail to compile.
- No panics via `@panic` anywhere (grep: zero), which is good; failure mode is mostly silent degradation instead.

Verdict for the port: the Program/Terminal/unicode/input layers are solid enough to build on. The component layer should be treated as a parts bin — Pi's transcript view, editor, and markdown rendering will need custom implementations anyway (consistent with the locked-in plan of a custom TranscriptView).

## Claim 13 — Exact insertion points for planned upstream contributions

**(a) ctrl_c / ctrl_z behavior option**
- Add option(s) to `Options` — src/core/context.zig:344-383, next to `suspend_enabled` (381-382). Suggested shape: `ctrl_c: enum { quit, forward } = .quit` (and optionally fold `suspend_enabled` into a matching `ctrl_z` enum, keeping the bool as deprecated alias).
- Change the hardcoded intercepts in `processKeyEvent` — src/core/program.zig:365-377: the `c == 'c'` branch (367-371) and the `c == 'z' and self.options.suspend_enabled` branch (373-376). Because raw mode sets `ISIG=false` (platform/posix.zig:100), forwarding is purely a matter of falling through to the `@hasField(UserMsg, "key")` dispatch at program.zig:397-400.

**(b) thread-safe `Program.post(msg)` mailbox + wake**
- State: add fields to the Program struct — program.zig:48-83 (e.g. `std.Io.Mutex`-guarded queue or MPSC ring + wake primitive). `DevConsole` (core/dev_console.zig:67, 197-198, `lockUncancelable`) is the in-tree pattern for `std.Io.Mutex` usage.
- API: `post()` beside `send()` — program.zig:875-879. `post` must only enqueue; dispatch must stay on the UI thread because `processCommand` writes to the terminal (program.zig:512-565) and `update` mutates the model.
- Drain point: inside `tick()`, after the input-event loop (program.zig:273-285) and before the timer blocks (287-320) — drain the queue, `dispatchToModel` + `processCommand` per message.
- Wake: the only blocking point is the end-of-tick pacing wait `deadline.wait(self.io)` — program.zig:343-347; input reads are non-blocking (`readInput(&input_buf, 0)` — program.zig:271; `Terminal.readInput` — terminal.zig:419-430). Two viable mechanisms: (i) a self-pipe/eventfd added to the poll set in `platform/posix.readInput` (posix.zig:158-174 currently polls only `stdin_fd`), switching tick to a blocking read with the remaining frame budget as timeout; (ii) replace `deadline.wait` with a wait on an `std.Io`-level event OR deadline. Windows (`platform/windows.zig`) and WASM (`platform/wasm.zig`) backends need equivalent treatment. Also fix or bypass `AsyncRunner` (claim 6) — a correct `post()` largely obsoletes it.

**(c) variable-height virtualization**
- src/components/virtual_list.zig: replace item-indexed scroll state (`cursor`, `offset`, `viewport_height` — virtual_list.zig:16-20) and `ensureVisible` (140-147) with row-based offsets backed by a per-item height source (either a `height_fn: fn(item, width) u16` field next to `render_fn` (28), or measuring render output via `measure.height` — src/layout/measure.zig / root.zig:318-320) plus a prefix-sum/partial-sum structure. `view()` (149-204) must clip partial top/bottom items and emit the scrollbar against total rows, not item count. Realistically this is a new sibling component (`VirtualRows`) — the current one's public contract (one row per item, scrollbar per item) is load-bearing for existing users.

**(d) render invalidation**
- src/core/program.zig `render()` (827-873): today `model.view` runs unconditionally every frame (828) and invalidation is only the post-hoc whole-string hash (831-834). Insertion: a `needs_render`/dirty flag on Program (fields 76-77 area, next to `last_view_hash`/`last_line_count`), set in `dispatchToModel` (353-361) or `processCommand`, on resize (254-267), on timer fire (287-320), and in `performSuspend` (which already forces redraw via `last_view_hash = 0` — 466); skip calling `view()` when clean; plus a public `requestRender()` for cases where the model mutates outside update. A deeper follow-up would be wiring the existing but unused cell double-buffer (terminal/screen.zig) into `render()` for per-cell damage instead of full-line rewrites — much larger change.

## Claim 14 — Vendored-copy deltas vs the main-branch reading

Nothing in the vendored tree **contradicts** the doc's claims — every claim above verified against this exact copy. Deltas and version-sensitive facts worth pinning:

1. **Ship manifest**: examples/ and tests/ are absent from the package (build.zig.zon:6-12 vs build.zig:15-116). A main-branch checkout has them; the vendored dependency does not. Plan snapshot tests in pi.zig's own tree.
2. **Three-arg init**: `Program.init(allocator, io, environ_map)` with `*const std.process.Environ.Map` (program.zig:87-93). Docs written from an older main may show a two-arg form; this copy also carries the full `Environment` capture layer (core/environment.zig) with TERM/COLORTERM/NO_COLOR/COLORFGBG/tmux/zellij/kitty-window detection.
3. **Frame pacing is newer/more elaborate than a simple sleep**: absolute-deadline pacing with `pacing_epoch`/`pacing_frame_offset` rebase on overrun/suspend (program.zig:61-73, 326-349) — any port doc describing "sleep per frame" is stale.
4. **Suspend/resume timer re-anchoring** (program.zig:444-463) and one-shot tick delta semantics (`pending_tick_scheduled_at`, message.zig:21-34) are refined beyond a basic Bubble-Tea port.
5. Features present in this copy that older readings may not list: DevConsole (file/TCP sinks, thread-safe), Action system + CommandPalette registry integration, ScreenStack router with modal overlays, hitbox/mouse-interaction framework, flex layout engine, layer compositing, ANSI compression (`style/compress.zig`), OSC52 read (not just write), kitty text-sizing + mode-2027 detection, WASM platform target, Ghostty/WezTerm image-probe fallback referencing upstream issue #113 (terminal.zig:1052-1060).
6. `fps: 0` is not "uncapped" — it silently falls back to ~60fps (program.zig:327-330). If the port wants an uncapped or event-driven mode, that's part of insertion point (b)/(d).
7. README's "34+ components" undercounts this copy (53 component files).
8. Confirmed-exact items from the doc's reading: async_task.zig path and its unsynchronized queue; `suspend_enabled` as the only Ctrl-key option; `start`/`tick`/`run`/`isRunning`; VirtualList fixed-row assumption; Markdown full-source line walk; `?std.Io.File` custom I/O; kitty/iterm2/sixel support.

