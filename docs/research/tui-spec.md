# Pi (oh-my-pi) UI Behavioral Spec for the ZigZag Port

All paths are relative to `/home/autark/src/zig/pi.zig/inspiration/`. Line numbers cite the vendored source.

---

## 1. The `packages/tui` framework

### 1.1 Architecture: retained tree, string-row contract

- **Retained-mode component tree**, not immediate-mode. `Component` interface: `render(width: number): readonly string[]` returning an array of *physical terminal rows* (pre-styled ANSI strings), plus optional `handleInput(data)`, `wantsKeyRelease`, `invalidate()`, `setIgnoreTight(bool)`, `dispose()` (`packages/tui/src/tui.ts:141-178`).
- **Render contract is reference-based memoization**: a component MUST return the *same array reference* when its content is unchanged and a *fresh array* whenever content changed. Reference equality is the engine's proof of byte-identical rows (`tui.ts:127-140`). Containers memoize concatenation on child refs (`Container`, `tui.ts:460-557`). In-place mutators instead implement `RenderStablePrefix.getRenderStablePrefixRows()` — a consumed-on-read count of leading rows unchanged since the engine last observed the array (`tui.ts:225-251`).
- `TUI extends Container` and is the root; children are stacked vertically. There is **no layout system** (no flexbox/grid): width flows down, each component decides its own rows.

### 1.2 Rendering: differential paint + append-only native scrollback

This is the defining design (header comment `tui.ts:1-13`, plus `docs/tui-core-renderer.md` referenced there):

- The frame is composed as one tall array of rows. Rows that scroll above the terminal window are **committed to native terminal scrollback exactly once, in order** — "the tape". Committed rows are immutable; the engine never rewrites history.
- A component can declare which of its rows are final via `NativeScrollbackLiveRegion.getNativeScrollbackLiveRegionStart()` (`tui.ts:202-204`): rows above the seam commit as *exact final bytes* (audited); rows below repaint in place in the visible window; if a still-live row scrolls off, it commits as a *frozen visual snapshot* that is audit-exempt forever. Topmost seam among root children wins (`tui.ts:1168-1170`).
- The engine feeds each child its committed-row claim back before render via `NativeScrollbackCommittedRows.setNativeScrollbackCommittedRows(rows)` (`tui.ts:206-212`) so a transcript can skip re-deriving committed blocks.
- **Commit audit / resync**: every ordinary frame compares the committed prefix against the current render, SGR-stripped (theme restyles are quiet). Verified zone is sampled: up to 8 non-blank rows in the last 24, tolerating exactly 1 mismatch; newly-final rows are hard-scanned with no tolerance; divergence re-anchors the commit index so content recommits *below* the frozen copy — "duplication, never loss" (`findCommittedPrefixResync`, `tui.ts:770-856`).
- `ED3` (`CSI 3 J`, clear scrollback) is emitted only for gesture-driven full paints: initial paint, session replacement, resize replay, `resetDisplay()` (`RenderIntent`, `tui.ts:559-572`). On multiplexers ED3/scrollback clears are avoided (`tui.ts:3486` passes `clearScrollback: !isMultiplexerSession()`).
- **Paint framing bytes**: `PAINT_BEGIN = hide-cursor + DEC-2026 sync-begin + autowrap-off`; `PAINT_END = autowrap-on + sync-end` (`tui.ts:66-78`). Every non-image row is terminated with `LINE_TERMINATOR = "\x1b[0m\x1b]8;;\x07"` (SGR reset + OSC-8 link close) so styles/links never bleed into scrollback (`tui.ts:43-49`). Diff repaints use relative cursor moves and `ESC[K`/`ESC[2K`.
- **SGR coalescing**: adjacent `CSI…m` runs are merged into one CSI (~40% of SGRs collapse), capped at 16 parameter tokens per merged CSI, guarding the ambiguous `38;2`/`38;5` semicolon color forms; `PI_NO_SGR_COALESCE=1` disables (`tui.ts:624-757`).
- **Hardware cursor**: components emit `CURSOR_MARKER = "\x1b_pi:c\x07"` (APC) at the cursor position; TUI strips it at frame ingestion and positions the real cursor there (for IME); `Focusable.setUseTerminalCursor()` toggles software vs hardware cursor (`tui.ts:283-317`, `1237-1253`). Hardware cursor is off by default (`PI_HARDWARE_CURSOR` flag, `tui.ts:953`).
- **Scheduling tiers**: `requestRender(force?)` (full compose, throttled to 30 fps min interval, plus adaptive floor: next delay inflated by last frame cost, capped at 200 ms ≈ 5 fps; ctrl+c/esc get one frame of input grace) (`tui.ts:876-893, 2241-2247`); `requestComponentRender(component)` re-renders only the containing root subtree, reusing all other segments (`tui.ts:1826-1836`); `requestDirectWrite(component)` rewrites an already-positioned quiet segment without the compose pipeline — used by spinners (`tui.ts:1847+`, `components/loader.ts:100-104`).
- **Resize**:
  - Multiplexer panes (tmux/screen/zellij): coalesce SIGWINCH bursts with a 50 ms debounce, repaint in place, never rewrap scrollback (`tui.ts:903, 1488-1497`).
  - Direct terminals: a drag enters a viewport fast path — borrow the **alt screen** for throwaway frames, compose only the visible tail via `ViewportTailProvider.renderViewportTail(width, maxRows)` (`tui.ts:274-281`), then one authoritative full replay after 120 ms of quiet (`tui.ts:917`).
  - Warp (re-reports size on alt-screen toggles) is routed through the in-place path; `PI_TUI_RESIZE_IN_PLACE=1|0` overrides (`tui.ts:377-392`).
  - ConPTY/Windows Terminal: 150 ms post-full-paint settle window coalescing non-forced renders; frames over 512 KB are truncated retaining 64 KB (`tui.ts:939-941`).
  - Ghostty: first image paint delayed 100 ms after start (`tui.ts:921`).
- `resetDisplay()`: keyboard-accessible full replay (invalidate all + clear + rewrite scrollback) — bound to ctrl+l (`tui.ts:1758-1774`).
- `stop()` places the shell prompt on the first line after content, computing exact cursor moves; scrolls exactly one line if content reaches the bottom (`tui.ts:1720-1741`).

### 1.3 Overlays

- `showOverlay(component, options)` pushes onto an overlay stack; returns handle `{hide, setHidden, isHidden}` (`tui.ts:1357-1408`). Options: `width`/`minWidth`/`maxHeight` (absolute or `"NN%"`), `anchor` (9 positions), `offsetX/Y`, `row/col`, `margin`, `visible(w,h)` predicate, `fullscreen` (`tui.ts:398-443`). Default width `min(80, avail)` (`tui.ts:2349`).
- `fullscreen: true` borrows the **alternate screen** (`CSI ?1049h`) vim-style — transcript untouched underneath; kitty keyboard flags are re-pushed per screen (`tui.ts:433-442, 1686-1692`).
- **Mouse reporting is enabled only while a fullscreen overlay is up**: `?1000h ?1003h ?1006h` (click + any-motion + SGR coords) so the normal app keeps native text selection (`tui.ts:79-85`). `mouse.ts` parses SGR mouse events; selectors route hover/click via `modes/components/select-list-mouse-routing.ts`.
- Focus: overlay owns focus; `OverlayFocusOwner.ownsOverlayFocusTarget()` lets an overlay delegate to inner components; hide restores `preFocus` (`tui.ts:180-184, 1323-1346`).
- Global debug key **shift+ctrl+d** handled by TUI before focus dispatch (`tui.ts:870, 2270-2274`).

### 1.4 Input pipeline & terminal setup (`terminal.ts`)

`ProcessTerminal.start()` (`terminal.ts:538-630`):
1. raw mode + utf8; save prior raw state; headless mode (tests) suppresses all real I/O.
2. Enable **bracketed paste** `CSI ?2004h`.
3. `process.stdout` `resize` listener (authoritative geometry); self-SIGWINCH on POSIX to refresh stale size after resume.
4. Windows: FFI `SetConsoleMode` to add `ENABLE_VIRTUAL_TERMINAL_INPUT`.
5. **Kitty keyboard protocol**: query `CSI ?u`; any reply ⇒ supported; push `CSI >1u` (disambiguate) normally or `CSI >7u` when reported flags ≥ 3; popped with a single `CSI <u` at teardown; per-screen flags re-pushed on alt-screen enter (`terminal.ts:906-925, 346-351`). If DA1 arrives first (no kitty), falls back to xterm **modifyOtherKeys** `CSI >4;2m` (undone if kitty replies late) (`terminal.ts:503, 897-905`).
6. **OSC 11** background-color query with **DA1 sentinel** (`\x1b[c`) for dark/light theme detection; **DEC mode 2031** appearance-change notifications re-query OSC 11 with 100 ms debounce (`terminal.ts:591-614, 993-1014`). No polling (it wiped selections).
7. **OSC 99** notification-capability query (kitty).
8. **DECRQM** probes: 2026 (sync output — reconciled at runtime by TUI, `tui.ts:1462-1466`), 2048 (in-band resize, enabled only on confirm; report format `CSI 48;rows;cols;ypx;xpx t` with sub-parameter tolerance), 2031; xterm scroll-to-bottom modes ?1010/?1011 are *disabled*.
9. Emergency-restore registration; teardown writes: disable 2004/2048, pop kitty, disable mouse, exit alt screen, show cursor (`terminal.ts:296-310`).
- **StdinBuffer** splits batched stdin into individual key sequences with a 50 ms flush timeout (bare-ESC latency vs split-CSI reassembly tradeoff); fast path skips regex probes for non-ESC bytes so large pastes don't melt the loop; reassembles split DA1/kitty/DECRPM/OSC-11/2048 replies (`terminal.ts:690-800`).
- Progress indicator OSC `9;4` sequences (`terminal.ts:17-18`); `setTitle` via interface (`terminal.ts:376`).

### 1.5 Key parsing & keybinding registry

- `keys.ts`: `matchesKey(data, keyId)` / `parseKey(data)` backed by **native (Rust) parsers** in `@oh-my-pi/pi-natives` (`keys.ts:21-26`, `547-561`). Handles legacy sequences, kitty CSI-u (with shifted-key/base-layout fields, event types `:2` repeat / `:3` release, lock-bit masking, numpad text mapping), modifyOtherKeys `CSI 27;mod;code~`. Release events are filtered unless component sets `wantsKeyRelease` (`tui.ts:2293-2296`). Raw 0x08 = ctrl+backspace on Windows Terminal, plain backspace elsewhere (`keys.ts:38-52`).
- KeyId grammar: `[ctrl+][shift+][alt+][super+]base`, canonical modifier order ctrl,shift,alt,super; shifted symbols get `shift+` aliases; uppercase letter implies shift (`keybindings.ts:144-223`).
- `KeybindingsManager`: definitions + user overrides, conflict detection, `matches(data, id)` (`keybindings.ts:242-324`). User config: `keybindings.yml`/`.yaml` (legacy `.json` migrated), profile-inherited merge (`coding-agent/src/config/keybindings.ts:369-510`).

### 1.6 tui component inventory

| Component | File | Notes |
|---|---|---|
| `Container` | tui.ts | vertical stack, memoized |
| `TUI` | tui.ts (3964 L) | root, renderer, overlays, focus |
| `Text` | components/text.ts | styled text, padding |
| `Spacer` | components/spacer.ts | N blank rows |
| `Box` | components/box.ts | padded/bg-tinted block |
| `TruncatedText` | components/truncated-text.ts | clamp to N rows |
| `Loader` | components/loader.ts | braille spinner `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, 80 ms glyph advance, direct-write path |
| `CancellableLoader` | components/cancellable-loader.ts | loader + esc handling |
| `Editor` | components/editor.ts (3194 L) | full multiline editor (see §2.6) |
| `Input` | components/input.ts | single-line prompt (modal API-key/OTP inputs), exposes `pasteText` |
| `Markdown` | components/markdown.ts (2277 L) | see §2.3 |
| `ScrollView` | components/scroll-view.ts | scrollable region for overlays |
| `SelectList` | components/select-list.ts | filterable list, selection highlight |
| `SettingsList` | components/settings-list.ts | key/value settings browser |
| `TabBar` | components/tab-bar.ts | overlay tab strips |
| `Image` | components/image.ts | terminal graphics (see §1.7) |

Support modules: `autocomplete.ts` (providers + popup logic, 1076 L), `fuzzy.ts` (fuzzy matcher), `kill-ring.ts` (emacs kill ring), `bracketed-paste.ts` (assembler `\x1b[200~…\x1b[201~`), `deccara.ts` (DECCARA rectangular-fill planning, gated on `TERMINAL.deccara && syncOutput`, `tui.ts:1317-1321`), `loop-watchdog.ts` (event-loop stall logger), `latex-to-unicode.ts` (2017 L) + `latex-block.ts` (1230 L), `stdin-buffer.ts`, `terminal-capabilities.ts` (1168 L), `desktop-notify.ts`, `kitty-graphics.ts`, `symbols.ts` (SymbolTheme: cursor, box round/sharp, table, quote border, hr char, color swatch, spinner frames).

### 1.7 Image support

- Protocols: **Kitty** (`\x1b_G`), **iTerm2** (`\x1b]1337;File=`), **Sixel** (DCS `q`) (`terminal-capabilities.ts:13-17`). Detection by terminal id; Windows Terminal probes sixel at TUI start via DA1 attribute 4 + XTSMGRAPHICS `CSI ?2;1;0S`, 250 ms timeout (`tui.ts:1531-1655`).
- Cell pixel size queried with `CSI 16 t`, response `CSI 6;h;w t` (`tui.ts:1656-1664, 2302-2320`).
- Kitty path supports **Unicode placeholders** (`U=1` + U+10EEEE + 297 row/column combining diacritics, max 297×297 cells) so images live in the text grid and survive reflow (`kitty-graphics.ts:1-60`); transmit/placement/delete encoders (`terminal-capabilities.ts:658-716`); deletes issued on `stop()`.
- **ImageBudget**: at most 8 (default) most-recent inline images stay live graphics; older ones demote to a text fallback line via graphics purge + full redraw; keyed by stable `imageKey` (`toolCallId:index`) so repaints replace placements (`components/image.ts:38-127`).
- Dimension sniffers for PNG/JPEG/GIF/WebP base64; `imageFallback(mime, dims, filename)` renders a text chip.
- Sixel passthrough of tool/bash output is supported (masked lines skip sanitization; `coding-agent/src/utils/sixel.ts` used by bash/tool components).

### 1.8 Notifications, title, bell

- `TERMINAL.sendNotification(message|{title,body,urgency})` (`terminal-capabilities.ts:93-142`): protocol per terminal — **OSC 99** (kitty, rich form only after capability confirmation), **OSC 9** (iTerm2/WezTerm/ConEmu-style), else **BEL**. Inside tmux: OSC wrapped in DCS passthrough + trailing BEL (feeds `monitor-bell`); inside zellij: OSC + bare BEL. On Linux+BEL-only terminals with a session bus, falls back to D-Bus `notify-send`/`gdbus` toast (app name "Oh My Pi", 5 s expiry) unless `PI_NO_DESKTOP_NOTIFY=1` (`desktop-notify.ts`).
- Terminal title: **OSC 0** `omp` / `omp: <session name>`; title save/restore via xterm window ops `CSI 22;2t` / `CSI 23;2t` on start/exit; control chars stripped from model-generated titles (`coding-agent/src/utils/title-generator.ts:344-393`). Session titles are auto-generated by a tiny local model after the first substantive prompt (`input-controller.ts:815-847`).
- Progress OSC `9;4;3` (indeterminate) / `9;4;0` (clear) (`terminal.ts:17-18`).

---

## 2. The coding agent's UI (`packages/coding-agent/src/modes`)

### 2.1 Root layout (top→bottom child order, `interactive-mode.ts:876-934`)

1. Optional warning `Text`, then **WelcomeComponent** (logo box: version, model/provider, exactly 4 recent-session rows + 4 LSP rows for stable height, weighted random tip with rainbow `NEW!` tag animated at 1500 ms hue period; intro animation; render cached by width) framed by `Spacer(1)`s; optional `DynamicBorder` + "What's New" changelog `Markdown` between borders (`welcome.ts`, `interactive-mode.ts:879-916`).
2. `chatContainer: TranscriptContainer` — the transcript.
3. `pendingMessagesContainer` (queued-message list), `todoContainer` (todo HUD), `subagentContainer` (Subagents HUD, max 8 rows + "… N more running — open Agent Hub for full list", `interactive-mode.ts:353-404`), `btwContainer`, `omfgContainer`, `errorBannerContainer` (pinned error banner), `modelCycleContainer` (ctrl+p role chip track, auto-clears after 4000 ms).
4. `statusContainer` — an `AnchoredLiveContainer` that reports seam 0 while non-empty so HUD/loader rows are never committed to scrollback (`interactive-mode.ts:334-347`). The "Working…" `Loader` lives here.
5. `statusLine` component (renders only hook statuses as rows — the main status line lives in the editor's top border).
6. `hookWidgetContainerAbove` (+leading `Spacer(1)`), `editorContainer` (the `CustomEditor`), `hookWidgetContainerBelow`.

The **FooterComponent** (`components/footer.ts`) renders: line 1 dim `~/short/path (branch)` (git branch read from `.git/HEAD`, fs-watched); line 2 dim stats `↑{in} ↓{out} R{cacheRead} W{cacheWrite} ${cost} ★ {premium} (sub) {context%} (auto)` left + `model-id • thinkinglevel` right-aligned, with cell-accurate truncation; optional extension-status line. Context % is colored by usage thresholds.

### 2.2 Transcript semantics (`components/transcript-container.ts`)

- `TranscriptContainer` assembles blocks with **exactly one blank separator row** between visible blocks; each block's plain-blank edges are stripped so the container owns gaps (`transcript-container.ts:84-99, 421-426`).
- Blocks implement `FinalizableBlock`: `isTranscriptBlockFinalized()`, `getTranscriptBlockVersion()` (post-finalize mutations), `getTranscriptBlockSettledRows()` (frozen-prefix commit of a *streaming* block, e.g. markdown's frozen token prefix), `isDisplaceableBlock()`/`seal()` (todo/job snapshot retraction) (`transcript-container.ts:16-55`). The commit seam = leading finalized blocks + first live block's settled rows; blocks whose rows entered the tape can no longer be retracted and get sealed (`transcript-container.ts:290-309`).
- **Scrolling model: there is no internal transcript scrolling.** History lives in native terminal scrollback; the user scrolls with the terminal. "Follow bottom" is implicit — the visible window is always the frame tail. Consequences: whole-transcript restyles (tool expand, thinking visibility, theme) must call `ui.resetDisplay()` to clear + replay scrollback (`input-controller.ts:1836-1844, 1872-1878`).
- User messages wrap OSC 133 zone marks `\x1b]133;A\x07` … `\x1b]133;B\x07` around their rows (no `133;C`) for terminal prompt-jumping (`components/user-message.ts:6-67`).

### 2.3 Markdown rendering subset (`packages/tui/src/components/markdown.ts`)

Lexed with **marked**; supported block tokens: `heading` (H1 optionally rendered as Kitty OSC 66 double-size span when `TERMINAL.textSizing`), `paragraph`, `code` (fenced, bordered, syntax-highlighted via theme hook), `list` (ordered/unordered, nested), `table` (GFM, box-drawing borders from SymbolTheme), `blockquote` (quote border glyph), `hr` (theme hr char), `html` (normalized subset: `br p ol ul li span text code hr blockquote`, entity decoding), `space` (`markdown.ts:1495-1642`). Inline: `strong`, `em`, `del` (strict `~~` regex), `link` (OSC 8 hyperlink when enabled), `codespan` (with inline **color swatches** for hex colors), text, and **LaTeX math** → Unicode approximation (`latex-to-unicode.ts`) with display-block layout (`latex-block.ts`). Mermaid fences are rendered to ASCII asynchronously by the app layer (`modes/theme/mermaid-cache.ts`) and defer scrollback settling (`assistant-message.ts:41-71`). Streaming markdown keeps a frozen-token-prefix so already-rendered rows stay byte-stable (referenced throughout transcript settling). Syntax highlighting is **native Rust** (`highlightCode` from `@oh-my-pi/pi-natives`, `theme.ts:9`).

### 2.4 Message rendering

- **User** (`user-message.ts`): Markdown with `userMessageBg` background + `userMessageText` fg (a filled "bubble"), 1-col padding; magic keywords ("ultrathink"/"orchestrate"/…) gradient-highlighted; image/paste placeholders rendered as bold-underlined accent hyperlinks; synthetic messages dim.
- **Assistant** (`assistant-message.ts`, 869 L): container of Markdown children per content block (fast path reuses Markdown children while streaming shape is stable). Thinking blocks: formatted (prose-only mode default), hidden per `hideThinkingBlock`+thinking-level; while hidden and streaming, an animated **starburst pulse** `✻ ✼ ❉ ❊ ✺ ✹ ✸ ✶` with raised-cosine dwell 70–230 ms plus a **tok/s speed badge** (3 s windowed average, clamp 200, gray→accent color lerp) and dim token count (`assistant-message.ts:74-235`). Turn-ending provider errors render inline capped at **8 non-blank lines** (`assistant-message.ts:13-19`), suppressed while pinned in the error banner. A slim **cache-invalidation divider** appears above turns that lost prompt cache (`cache-invalidation-marker.ts`). Tool-result images attach to the message; Kitty needs async PNG conversion.
- **Compaction summary**, **skill**, **hook**, **custom (extension)**, **collab prompt**, **advisor** messages each have small dedicated components (`components/*.ts`).

### 2.5 Tool-call presentation (`components/tool-execution.ts`, `tools/renderers.ts`)

- Per-tool renderer registry: `ask, ast_grep, ast_edit, bash, browser, debug, eval, edit, apply_patch, glob, grep, lsp, inspect_image, irc, read, job, resolve, retain, recall, reflect, search_tool_bm25, ssh, task, todo, github, goal, web_search, vibe_*, write` (`tools/renderers.ts:81-121`). Renderer contract: `renderCall(args)`, `renderResult(result, opts)`, flags `mergeCallAndResult`, `inline` (no background box), `animatedPendingPreview`, `animatedPartialResult`, `forceFirstResultViewportRepaint`, `forceResultViewportRepaintOnSettle` (`renderers.ts:45-79`).
- Blocks are visually distinct cards: background-tinted `Box(0,1)` for custom/renderer tools, `WidthAwareText` generic fallback otherwise; `setIgnoreTight(true)` keeps padding in tight mode (`tool-execution.ts:329-347`). Unknown/generic tools render args as a JSON tree with collapsed/expanded depth/line/scalar limits (`tools/json-tree.ts` constants).
- **Collapsed/expanded**: global toggle ctrl+o (`app.tools.expand`) walks all chat children calling `setExpanded(bool)` then `resetDisplay()` (`input-controller.ts:1824-1844`). Collapsed previews are ~20 lines (bash `BASH_DEFAULT_PREVIEW_LINES`, eval equivalent), with `… N more lines (ctrl+o to expand)` footers.
- **Spinners**: live blocks repaint at 80 ms, phase-locked across parallel tools via `sharedSpinnerFrame(now/80 % frames)` (`tool-execution.ts:187-201`).
- **Edit/apply_patch streaming diff preview**: as args stream (~30 fps reveal), a whole-file Myers diff preview is recomputed **single-flight with coalescing** (never cancel in-flight; re-run if dirty), keyed by content hash + stream/final flag; trailing unbalanced `-`/`@@` runs are stripped so removals never render before their additions ("removals first" jitter fix) (`tool-execution.ts:47-110, 398-480`).
- Result lifecycle: `updateArgs` → `setArgsComplete` → `updateResult(isPartial?)` → `seal()`; unsealed blocks pin the transcript live region so late results still repaint. Detached background `task` blocks freeze to static gray once they leave the live region and drop further partial snapshots (`tool-execution.ts:482-500, 271-295`). `todo`/`job` snapshots are displaceable: a newer same-tool call retracts the previous card unless its rows already committed (then sealed in place).
- **Diff rendering** (`components/diff.ts`): line format `±NNN|content`; removed = `toolDiffRemoved` (red), added = `toolDiffAdded` (green), context = `toolDiffContext` (dim) with batch syntax highlighting; single-line replacements get **intra-line word diffs** with `inverse` on changed tokens (leading whitespace excluded); leading indentation visualized as dim `·` (space) and ` → ` (tab); duplicate line-number gutters blanked; gutter fixed at ≥3 digits so streaming growth never re-pads committed rows; non-contiguous regions render as a single dim `…`.

### 2.6 `!` bash / `$` python execution blocks

`bash-execution.ts` + `execution-shared.ts`: frame = `DynamicBorder` (full-width horizontal rule in mode color) above and below; header `$ <command>` bold in `bashMode` color (dim if `!!` excluded-from-context); streaming output dim/muted, collapsed to last 20 visual lines, input chunks throttled to one per 50 ms window, stored lines capped at 100 (20×5), each line clamped to 4000 columns with `… [N visible columns omitted]`; loader `Running… (esc to cancel)`; completion footer: hidden-line hint / `(cancelled)` warning / `(exit N)` error / truncation notice. Python (`eval-execution.ts`) mirrors it with a `>>>` header and `pythonMode` color. Sixel output passes through unsanitized.

### 2.7 The input editor

**Core `Editor`** (`packages/tui/src/components/editor.ts`):
- Multiline logical lines with word-aware wrap (cached per width); bordered box (rounded corners from SymbolTheme) with `paddingX` default 2, dynamic `borderColor` fn, optional custom **top border content** (the status line) supplied eagerly or via per-frame provider (`editor.ts:470-512`); optional borderless mode with prompt gutter.
- Max height: visible content scrolls inside (`#scrollOffset`); app computes cap `clamp(rows-12, 6, 18)`, min 3 rendered rows, keeping ≥4 rows of chrome on small terminals (`interactive-mode.ts:252-274`).
- **History**: 100 entries, no consecutive dupes, persisted via `HistoryStorage`; Up/Down navigate history when on first/last visual line or empty; PageUp/PageDown page-scroll or history-navigate (`editor.ts:567-626, 1367-1419`).
- **Kill ring** (ctrl+k/u/w kill; ctrl+y yank; alt+y yank-pop), **undo** (ctrl+- / ctrl+_), **character jump** (ctrl+] forward, ctrl+alt+] backward, next char jumps), sticky visual column for vertical moves.
- **Pastes**: bracketed pastes > 10 lines or > 1000 chars collapse to atomic `[Paste #N, +K lines]` markers, expanded on submit; `onLargePaste` hook lets the app intercept.
- **Autocomplete popup**: SelectList under the cursor, max visible 5 (configurable 3–20), debounced; Tab applies; Enter applies slash commands then submits (file paths apply only); Esc cancels popup (first Esc never reaches the interrupt handler, `custom-editor.ts:794-804`); stale-prefix guard; synchronous slash completion on fast Enter (`editor.ts:1098-1246, 1317-1355`).
- Submit: Enter; **newline**: shift+enter, ctrl+j, alt+enter fallback, `\`+Enter (backslash removed then submit? no — backslash-enter submits per `#shouldSubmitOnBackslashEnter`), legacy `\x1b\r`, `CSI 13;2~`, bare `\n`.
- **Cursor** rendered as marker (hardware) or inverse glyph (software).

**`CustomEditor`** (`modes/components/custom-editor.ts`) adds: configurable action-key interception table (see §3); custom key handlers (extensions, plan toggle, session keys); caps-lock detection (kitty mod bit 64) → `onCapsLock`; bracketed-paste router — empty payload ⇒ clipboard-image read, image-file path(s) ⇒ attach image, else text paste; async-paste serialization so a trailing Enter can't submit before the image lands; **space-hold push-to-talk** (OS auto-repeat cadence detector: 2 consecutive mechanical gaps ≤120 ms within 18 ms/35% jitter starts STT, 250 ms idle ends it); queue shorthand `->`/`=>` gets a dim `Queueing ➤` label and accent list markers; magic-keyword shimmer repaint at 70 ms frame / 1800 ms sweep; pending draft images `pendingImages`+`pendingImageLinks` cleared by `clearDraft`.
- **Border color state machine** (`interactive-mode.ts:1547-1573`): bash mode → bash color; python mode → python color; else session-accent hex (derived from session name) if enabled, else thinking-level color; dimmed (`SGR 2`) while a subagent is focused.
- Prompt modes by prefix: `!`/`!!` bash (excluded), `$ `/`$$ ` python (excluded), `/` slash commands, `->`/`=>` queue, plain text. Continue shortcuts: exactly `.` or `c` sends a hidden continue directive (`input-controller.ts:613-625`).

### 2.8 Status line (in editor top border)

`StatusLineComponent` renders a powerline-style string embedded in the editor's top border via `setTopBorderProvider` (`interactive-mode.ts:716`). Presets (`status-line/presets.ts`): `default` (left: pi, model, mode, collab, path, git, pr, context_pct, cost; right: session_name; separator powerline-thin), `minimal`, `compact`, `full`, `nerd`, `ascii`, `custom`. Segments (`status-line/segments.ts`): `pi` (icon; ghost icon + agent id when subagent focused), `model` (name minus "Claude " prefix, thinking-level display `◉ xhigh`/`⟳ auto`, fast-mode icon, advisor `++` badge), `mode`, `goal`, `path` (scratch-root classification, abbreviation), `git` (branch/staged/unstaged/untracked), `pr`, `context_pct` (threshold colors), `cost`, `session_name`, `hostname`, `subagents`, `token_in/out/total/rate`, `cache_read/write/hit`, `time_spent`, `time`. Options: session accent color, transparency, compact thinking level.

### 2.9 Streaming & loading indicators

- **Working loader**: `Loader` in `statusContainer`, message `Working… [esc]` (theme brackets) with shimmer gradient (session-accent palette); tool `intent` args replace the message live (`event-controller.ts:257-265`); auto-compaction and retry get their own loaders labeled with "(esc to cancel)".
- **Streaming reveal** (`controllers/streaming-reveal.ts`): typewriter reveal of streamed text/thinking at 30 fps, min 3 graphemes/frame, catches up within 8 frames; grapheme segmentation cached per block (append-only aware). Tool args have an equivalent reveal (`tool-args-reveal.ts`). Component-scoped renders keep 30 fps affordable.
- Session accent shimmer: `theme/shimmer.ts` gradient sweeps.

### 2.10 Dialogs / overlays / selectors

- Selectors (model, session, theme, settings, debug, copy, oauth, hook, tree, user-message fork) open via `ui.showOverlay(..., { anchor: "bottom-center", fullscreen: true })`; dashboards (agent, extension) use `anchor: "top-left", fullscreen: true` (`controllers/selector-controller.ts:209-1090`). The Agent Hub renders **inline in the editor slot**, not as an overlay (`selector-controller.ts:1468-1470`).
- **Session selector** (`session-selector.ts`, 1009 L): fuzzy list of sessions; ctrl+r rename, ctrl+d delete, ctrl+backspace non-invasive delete, ctrl+p toggle path display, ctrl+s toggle sort.
- **Model hub** (`model-hub.ts`, 2008 L) + `model-browser.ts`: role-model assignment, temporary model (alt+p), favorites; `thinking-selector.ts` levels.
- **Ask dialog** (`ask-dialog.ts`): bottom panel ≤70% of terminal height, min 12 rows; tabbed multi-question; single/multi select; "Other (type your own)" prompt row; markdown+code preview pane (side-by-side ≥40 cols); optional countdown timer; Esc cancels.
- **Plan review overlay** (`plan-review-overlay.ts`, 854 L): plan markdown + approve/keep-context options + model slider (segment track).
- **History search** (ctrl+r, `history-search.ts`): `Input` + 10-row scrollable result list, token highlighting, relative timestamps, PageUp/Down jumps.
- Extension UI: `showHookSelector` label/description lists, hook editor/input (modal `Input` with `pasteText`), extension widgets above/below editor.

### 2.11 Global state keys & lifecycle semantics

See §3 table; the Esc ladder and ctrl+c/d/z below are the authoritative behavior (`controllers/input-controller.ts:269-389, 951-1057`).

---

## 3. Complete keybinding table

### 3.1 Defaults (`tui` layer, `packages/tui/src/keybindings.ts:57-137`)

| ID | Default keys |
|---|---|
| tui.editor.cursorUp / Down | up / down |
| tui.editor.cursorLeft / Right | left, ctrl+b / right, ctrl+f |
| tui.editor.cursorWordLeft | alt+left, ctrl+left, alt+b |
| tui.editor.cursorWordRight | alt+right, ctrl+right, alt+f |
| tui.editor.cursorLineStart / End | home, ctrl+a / end, ctrl+e |
| tui.editor.jumpForward / Backward | ctrl+] / ctrl+alt+] |
| tui.editor.pageUp / pageDown | pageUp / pageDown |
| tui.editor.deleteCharBackward | backspace |
| tui.editor.deleteCharForward | delete, ctrl+d |
| tui.editor.deleteWordBackward | ctrl+w, alt+backspace, ctrl+backspace, super+alt+backspace |
| tui.editor.deleteWordForward | alt+delete, alt+d, super+alt+delete, super+alt+d |
| tui.editor.deleteToLineStart / End | ctrl+u / ctrl+k |
| tui.editor.yank / yankPop | ctrl+y / alt+y |
| tui.editor.undo | ctrl+-, ctrl+_ |
| tui.input.newLine | shift+enter, ctrl+j |
| tui.input.submit | enter |
| tui.input.tab | tab |
| tui.input.copy | ctrl+c |
| tui.select.up/down/pageUp/pageDown | up/down/pageUp/pageDown |
| tui.select.confirm | enter |
| tui.select.cancel | escape, ctrl+c |

### 3.2 App layer (`coding-agent/src/config/keybindings.ts:76-225`)

| ID | Default | Action |
|---|---|---|
| app.interrupt | escape | Esc ladder (below) |
| app.clear | ctrl+c | clear/double-press exit |
| app.exit | ctrl+d | shutdown (saves draft) |
| app.suspend | ctrl+z | SIGSTOP process group |
| app.display.reset | ctrl+l | `resetDisplay()` |
| app.thinking.cycle | shift+tab | cycle thinking level |
| app.thinking.toggle | ctrl+t | show/hide thinking blocks |
| app.model.cycleForward | ctrl+p | next role model (chip track shown 4 s) |
| app.model.cycleBackward | shift+ctrl+p | previous role model |
| app.model.select | alt+m | model selector |
| app.model.selectTemporary | alt+p | temp model for session |
| app.tools.expand | ctrl+o | toggle tool output expansion (+resetDisplay) |
| app.editor.external | ctrl+g | $VISUAL/$EDITOR on draft (.omp.md, /dev/tty stdio) |
| app.message.followUp | ctrl+q, ctrl+enter | send follow-up during stream (ctrl+q first for Windows Terminal) |
| app.retry | alt+r | retry last failed turn |
| app.message.dequeue | alt+up | restore queued messages into editor |
| app.clipboard.pasteImage | ctrl+v (+alt+v win, +super+v mac) | clipboard image paste |
| app.clipboard.pasteTextRaw | ctrl+shift+v, alt+shift+v | paste w/o marker collapse |
| app.clipboard.copyLine | alt+shift+l | copy current line |
| app.clipboard.copyPrompt | alt+shift+c | copy draft |
| app.agents.hub | alt+a | agent hub |
| app.session.observe | ctrl+s | agent hub |
| app.session.new / tree / fork / resume | (unbound) | /clear, /tree, fork selector, session selector |
| app.session.togglePath | ctrl+p (selector-scope) | toggle path in session selector |
| app.session.toggleSort | ctrl+s (selector-scope) | toggle sort |
| app.session.rename | ctrl+r (selector-scope) | rename session |
| app.session.delete | ctrl+d (selector-scope) | delete session |
| app.session.deleteNoninvasive | ctrl+backspace (selector-scope) | delete w/o touching files |
| app.tree.foldOrUp / unfoldOrDown | ctrl+left,alt+left / ctrl+right,alt+right | tree selector fold |
| app.plan.toggle | alt+shift+p | plan mode |
| app.history.search | ctrl+r | history search overlay |
| app.stt.toggle | (unbound; gesture = hold Space) | speech-to-text |

Hardcoded, not rebindable: **shift+ctrl+d** → debug selector (TUI global); double-tap **←** on empty editor (40–500 ms gap, burst-rejected) → Agent Hub / return from focused subagent (`input-controller.ts:156-157, 531-548`); **b** / **c** on empty editor when a btw panel is active → branch/copy; alt+enter → newline (or `onAltEnter`); shift+space → literal space.

### 3.3 State-dependent semantics

**Esc** (`input-controller.ts:269-389`, in priority order):
1. Autocomplete popup visible → dismiss popup only.
2. btw / omfg side panels → dismiss.
3. (main view) compaction / handoff generation / retry backoff in flight → abort those ("esc to cancel" advertised).
4. Loop mode on → pause loop + abort stream or cancel pending submission.
5. Focused subagent view → clear typed text, else return to main session (never interrupts the subagent turn).
6. Collab guest → send abort to host.
7. Loading animation → cancel pending submission, else restore queued messages to editor (with abort).
8. Bash running → abort bash; bash prompt mode → clear + exit mode; eval running → abort eval; python mode → clear + exit mode.
9. Streaming → abort turn (`USER_INTERRUPT_LABEL`).
10. Non-empty draft → do nothing (protect draft; resets double-esc timer).
11. TTS speaking → silence.
12. Empty & idle: double-Esc within 500 ms → `/tree` selector or user-message fork selector per `doubleEscapeAction` setting ("none" disables), then `resetDisplay()`.

**Ctrl+C**: editor never consumes it as text. Handler (`input-controller.ts:951-982`): sync-flush session JSONL; if already shutting down → hard `process.exit(130)`; double-press within 500 ms → `shutdown()`; single press → clear editor. In selectors/overlays: cancel (tui.select.cancel).

**Ctrl+D**: always `shutdown()` (draft snapshotted for next resume) (`input-controller.ts:984-989`). In selectors: delete session.

**Ctrl+Z** (`input-controller.ts:991-1057`): Windows → status "not supported". POSIX: hook SIGCONT (restart TUI + forced render), `ui.stop()`, then `process.kill(0, SIGSTOP)` to the whole foreground group (SIGTSTP is swallowed by embedded tokio handlers); on failure unhook + restart + error.

**Enter while streaming**: text → steer (queued); empty submit with queued messages → abort turn and drain queue. **Ctrl+Q/Ctrl+Enter** → follow-up queue. During compaction, input is queued for after compaction.

---

## 4. Degraded modes

- **Non-TTY / `-p`**: print mode — no TUI at all; text or JSON event stream to stdout (`modes/print-mode.ts`). `main.ts` gates interactive mode on `stdin.isTTY && stdout.isTTY`.
- **Headless (tests)**: `ProcessTerminal` suppresses every real write/probe/raw-mode change (`terminal.ts:542-547`).
- **ASCII / symbols**: `SymbolPreset = "unicode" | "nerd" | "ascii"` with full parallel symbol tables (box drawing kept unicode in ascii preset; separators become `>`/`<`) (`theme.ts:29, 295-296, 963-981`); status-line `ascii` preset avoids Nerd Fonts; per-preset spinner frames.
- **Color**: themes are JSON (dark/light + custom dir), applied per detected background (OSC 11 + mode 2031 live switching); color output encodes via truecolor or 256-color depending on `TERMINAL.trueColor` (e.g. `welcome.ts:114`); colorMode and color-blind mode options in theme loader (`theme.ts:2057-2098`). No explicit NO_COLOR path — degraded color = 256-color encoding + theme.
- **Narrow terminals**: editor cap shrinks to floor of 3 rendered rows keeping ≥4 chrome rows (`interactive-mode.ts:252-274`); overlay layout clamps to margins/percent (`tui.ts:2326-2360`); footer truncates by visible cells, drops right side under ~3 cols (`footer.ts:224-253`); welcome tip hidden when body budget < 8 cols; ask dialog min 12 rows / min body 5; the renderer clamps over-wide rows instead of throwing (`tui.ts:53-57`).
- **Multiplexers (tmux/screen/zellij)**: in-place resize (no alt-screen borrow, no ED3 rewrap — scrollback keeps old wrap); 50 ms SIGWINCH debounce; notifications via DCS passthrough (+BEL) or bare BEL; sync-output default off until DECRQM confirms.
- **Windows/ConPTY**: VT input enabling via FFI; post-paint settle 150 ms; 512 KB frame truncation; sixel probe for WT; ctrl+backspace 0x08 heuristic; ctrl+z unsupported; box-drawing mis-translation noted (`terminal.ts:220`).
- **No kitty keyboard protocol**: legacy escape parsing + xterm modifyOtherKeys `CSI >4;2m` fallback; kitty strictly preferred (`terminal.ts:897-925`).
- Env overrides: `PI_NO_SGR_COALESCE`, `PI_HARDWARE_CURSOR`, `PI_TUI_RESIZE_IN_PLACE`, `PI_NO_DESKTOP_NOTIFY`, `PI_NO_TITLE`, sync-output and hyperlink user overrides (`terminal-capabilities.ts:242, 342`).

---

## 5. Cheap vs expensive to reproduce in Zig; JS-runtime dependencies

**Cheap (straightforward in Zig/ZigZag):**
- The component model itself: `render(width) → []const []const u8` with reference/generation-based memoization maps directly to Zig slices + arena per frame.
- Keybinding registry + canonicalization; kitty CSI-u/modifyOtherKeys parsing (upstream already delegates to native Rust — a Zig parser is equivalent work).
- Editor core (lines, wrap cache, kill ring, undo, history), Input, SelectList, TabBar, Spacer, Text, Box, DynamicBorder, footer, status-line segments/presets, diff renderer, tool cards, execution frames, loaders/spinners, queue shorthand decoration.
- OSC title/notify/progress emission, bracketed paste assembly, StdinBuffer sequence splitting, overlay geometry.

**Medium:**
- Markdown: need a Zig CommonMark+GFM-tables subset lexer replicating §2.3 exactly (frozen-prefix streaming is the subtle part: byte-stable already-emitted rows).
- Syntax highlighting: upstream uses a native Rust highlighter via pi-natives; Zig needs tree-sitter or a smaller lexer set — scope to the languages the diff/code views actually show.
- Width/grapheme handling: upstream leans on `Intl.Segmenter` + native width tables (`visibleWidth`, `sliceByColumn`, Hangul-jamo width quirks, `terminal.ts:589`). Zig needs a Unicode width + grapheme library (ZigZag may provide).
- Terminal capability probing state machine (DA1 sentinel FIFO for OSC 11/OSC 99/DECRQM/kitty, split-reply reassembly).
- Streaming reveal (grapheme typewriter) — mechanical but touchy.

**Expensive (the real engineering):**
- The **append-only native-scrollback engine**: commit ledger, exactness seams, frozen snapshots, stable-prefix propagation (`TranscriptContainer` ↔ `TUI.render`), committed-prefix audit with SGR-stripped tolerance sampling, displaceable-block sealing, and the resize triptych (multiplexer debounce / alt-screen viewport fast path + `renderViewportTail` / ConPTY settle). This is ~2500 lines of invariant-dense logic and is the part that makes the transcript feel native. A first Zig milestone can ship a simpler "repaint window + append finalized blocks once" engine and grow the audits later, but the *contract* (blocks are immutable once finalized; one blank separator; expansion toggles force full replay) should be designed in from day one.
- **Image support**: three protocols, kitty Unicode placeholders, ImageBudget purge/redraw, PNG conversion for kitty, cell-size probing. Suggest phase-gating: text fallback first, kitty direct placement second.
- **LaTeX→Unicode** (2 kLoC of tables) and **mermaid ASCII rendering** (async JS library + cache) — mermaid is the single clearest candidate to drop or route through quickjs; it already defers scrollback settling upstream, so omitting it is behaviorally safe.
- Kitty OSC 66 sized headings, DECCARA fill optimization, SGR coalescing — pure optimizations; safe to omit initially (they are all behavior-preserving byte reductions).

**JS-runtime-dependent (must route through zig-quickjs-ng or be redesigned):**
- **Extension custom tool renderers**: `tool.renderCall/renderResult` return live `Component` objects from extension JS (`tool-execution.ts:339-344`); extension **widgets** above/below the editor (`extension-ui-controller.ts:279-343`), extension status entries in the footer, custom messages (`custom-message.ts`), extension shortcuts (`input-controller.ts:1938-1957`), extension ask-dialogs/selectors (`ExtensionUIContext`). For the port these should become a *declarative* bridge (extension returns text/markdown/rows, host renders) rather than exposing the component tree to quickjs.
- Theme JSONs, tips.txt, changelog markdown are plain data — portable as-is.
- The tiny-model title generation and STT/TTS integrations are outside the UI layer but surface UI affordances (download progress bar component, space-hold gesture) that can be stubbed.

**Recommended parity tiers for the ZigZag frontend:** T0 = root layout, transcript with simple append/repaint, editor + keybindings + Esc/ctrl+c ladders, footer/status-line, loaders, diff/tool/bash cards, selectors as bottom-anchored fullscreen overlays, kitty keyboard + bracketed paste, OSC title/notify. T1 = native-scrollback commit engine with seams and audits, resize fast paths, history search, ask dialog, plan overlay. T2 = images, OSC 66, sixel passthrough, mermaid/LaTeX, extension-rendered UI via quickjs bridge.
