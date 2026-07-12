# oh-my-pi Built-in Tools — Re-implementation Spec for the Zig Port

Source of truth: `/home/autark/src/zig/pi.zig/inspiration` (oh-my-pi monorepo). Tool implementations live in `packages/coding-agent/src/tools/` (plus `src/edit/`, `src/task/`, `src/web/search/`, `packages/hashline/`). Model-facing description texts live in `packages/coding-agent/src/prompts/tools/*.md`; distilled behavioral docs in `docs/tools/*.md`; the bash runtime doc is `docs/bash-tool-runtime.md`.

---

## 1. Registry & common infrastructure

### 1.1 Tool names
Canonical built-in names (`src/tools/builtin-names.ts:1`): `read, bash, edit, ast_grep, ast_edit, ask, debug, eval, ssh, github, glob, grep, lsp, inspect_image, browser, checkpoint, rewind, task, job, irc, todo, web_search, search_tool_bm25, write, memory_edit, retain, recall, reflect, learn, manage_skill`. Legacy aliases: `search → grep`, `find → glob` (builtin-names.ts:36). Hidden tools (`src/tools/index.ts:481`): `yield, report_finding, report_tool_issue, resolve, goal`. `resolve` is always injected even when a whitelist omits it (index.ts:670).

Default **essential** tools (`DEFAULT_ESSENTIAL_TOOL_NAMES`, index.ts:389): `read, bash, edit, write, glob, eval`. Everything else is `loadMode: "discoverable"` and can be hidden behind `search_tool_bm25` when `tools.discoveryMode === "all"`.

Availability gates (index.ts:604-639): `bash.enabled`, `todo.enabled` (and not when yield tool present), `glob.enabled`, `grep.enabled`, `lsp.enabled`, `github.enabled`, `astGrep.enabled`, `astEdit.enabled`, `inspect_image.enabled` (default false), `web_search.enabled`, `ask.enabled` (UI only), `browser.enabled`, `checkpoint.enabled` (default false, gates checkpoint+rewind), `debug.enabled`, memory tools by `memory.backend ∈ {hindsight, mnemopi}`, `learn`/`manage_skill` by `autolearn.enabled` + taskDepth 0, `task` by `task.maxRecursionDepth` (default 2), `eval` by backend availability, `irc` derived (subagent, or can spawn subagents).

### 1.2 Common result/error plumbing
- Tools return `AgentToolResult`: `{ content: Array<{type:"text",text} | {type:"image",data,mimeType}>, details?, isError? }`. Built via `toolResult()` (`src/tools/tool-result.ts`).
- **Errors**: `ToolError` (message shown to model as error result) and `ToolAbortError` (default message constant; user abort) in `src/tools/tool-errors.ts:12,30`. Non-zero bash exit is an `isError` result, not a throw.
- **Tool tiers for approval**: `read` tool is tier "read" (tier "exec" when the path targets `ssh://`), `edit` is "write" ("read" for internal URLs), etc.
- **Concurrency flags**: `edit`/`write`/`todo`/`ask`/`ssh` are `concurrency: "exclusive"`; `bash` is per-call (`pty:true` → "exclusive", else "shared"); others default shared. `strict = true` on read/bash/edit/write/todo (schema strictness).
- **Truncation core** (`src/session/streaming-output.ts:10-22`): `DEFAULT_MAX_LINES = 3000`, `DEFAULT_MAX_BYTES = 50*1024`, `DEFAULT_MAX_COLUMN = 512` (grep line cap), `ARTIFACT_DEFAULT_HEAD_BYTES = 3 MiB`. `truncateHead()` keeps head up to line/byte cap; `OutputSink` keeps a UTF-8-safe rolling **tail** window (spill threshold 50 KB), optional head window (`tools.artifactHeadBytes`, default 20 KB) with a middle-elision marker, per-line column cap (`tools.outputMaxColumns`, default 768 bytes), and mirrors the raw uncapped stream to an artifact file on overflow.
- **Truncation notices** appended by `wrapToolWithMetaNotice()` (every built-in is wrapped, index.ts:666). Exact formats (`src/tools/output-meta.ts:384-480`): artifact ref `Read artifact://<id> for full output`; tail/head form `Showing lines A-B of N` [`+ " (X KB limit)"` when byte-truncated] [`. Use :<nextOffset> to continue`] [`. Read artifact://<id> for full output`]; middle-elision form `Showing lines A-B and C-D of N; K middle lines (X KB) elided`. Bash minimizer footer: `[raw output: artifact://<id>]`.
- **Timeout clamps** (`src/tools/tool-timeouts.ts:10`): bash `{default 300, min 1, max 3600}`, eval `{30,1,3600}`, browser `{30,1,300}`, ssh `{60,1,3600}`, fetch `{20,1,45}`, lsp `{20,5,60}`, debug `{30,5,300}` (seconds). `clampTimeout(tool, raw)` = `max(min, min(max, raw ?? default))`.
- **File display mode** (`src/utils/file-display-mode.ts:29`): `hashLines = !raw && !immutable && hasEditTool && editMode==="hashline"`; `lineNumbers = !raw && (hashLines || settings.readLineNumbers)`. Default edit mode is `hashline` (`src/utils/edit-mode.ts:5`); models matching "kimi" fall back to `replace` unless `PI_STRICT_EDIT_MODE`.
- **Session snapshot store** (hashline anchors): `InMemorySnapshotStore` (`packages/hashline/src/snapshots.ts`): LRU of 30 paths (`DEFAULT_MAX_PATHS`), 4 versions/path (`DEFAULT_MAX_VERSIONS_PER_PATH`), 64 MiB global text ceiling; files > 4 MiB (`SNAPSHOT_MAX_BYTES` in `src/edit/file-snapshot-store.ts`) are not snapshotted. Tags are minted by `computeFileHash()`.
- **TUI preview caps** (`src/tools/render-utils.ts:48`): `COLLAPSED_LINES 3`, `EXPANDED_LINES 12`, `COLLAPSED_ITEMS 8`, `OUTPUT_COLLAPSED 3`, `OUTPUT_EXPANDED 10`, `DIFF_COLLAPSED_HUNKS 8`, `DIFF_COLLAPSED_LINES 40`.

---

## 2. read

Source: `src/tools/read.ts` (3614 lines). Prompt: `src/prompts/tools/read.md`. Doc: `docs/tools/read.md`.

**Identity**: name `read`, label `Read`, loadMode essential, `strict: true`. Approval tier "read" ("exec" for ssh:// paths).

**Description sent to model** (templated with `DEFAULT_LIMIT`, hashline/line-number mode, inspect_image flags): "Read files, directories, archives, SQLite, images, documents, internal resources, and web URLs via `path` plus optional `selector`." plus instructions to parallelize independent reads, full selector grammar (`:50`, `:50-200`, `:50+150`, `:5-16,960-973`, `:raw`, `:2-4:raw`, `:conflicts`), hashline note ("Copy `[FILENAME#TAG]` for anchored edits; ops use bare line numbers. NEVER fabricate the tag."), document/notebook/image/archive/SQLite/URL sections, and criticals ("Literal colon filename + selector? Use `selector`…", "Summary footer names elided ranges? Re-issue ONLY those ranges").

**Input schema** (read.ts:749):
- `path: string` (required) — 'Local path, internal URI (e.g. "omp://", "issue://123", "pr://123"), or URL. Inline :<sel> is still accepted for compatibility.'
- `selector?: string` — 'selector without a leading colon (e.g. "50-100", "raw", "raw:50-100", "conflicts"); keeps `path` literal when filenames contain colons'

**Selector grammar** (`path-utils.ts` `parseLineRanges` / read.ts `parseSel`): `:raw`, `:conflicts`, `:N` / `:N-` (open-ended, 1-indexed), `:A-B` inclusive (`..` alias), `:A+C` (C lines from A ⇒ end = A+C-1), comma-separated multi-ranges (sorted+merged), compound `range:raw` / `raw:range`. Validation: `:0` → error `Line selector 0 is invalid; lines are 1-indexed. Use :1.`; `+` count ≥ 1; end ≥ start. Invalid selector error: ``Invalid selector ':<sel>'. Use :N, :N-M, :N+K, :N- (open-ended), a comma-separated list of ranges, :raw, or a range combined with raw (e.g. :raw:50-100).`` Unrecognized trailing `:...` falls through (archives/sqlite consume their own colon syntax).

**Dispatch order** in `execute`: (1) delimited multi-path input (`splitDelimitedPathEntry` — one call rendered as multiple reads; per-part errors become `[Could not read <part>: <msg>]` notes); (2) web URL (`parseReadUrlTarget`: `http://`, `https://`, `www.`); (3) internal URL via `InternalUrlRouter` (`agent://, artifact://, history://, issue://, local://, mcp://, memory://, omp://, pr://, rule://, skill://, vault://`); (4) archive (`.tar`, `.tar.gz`, `.tgz`, `.zip` with `:inner/path`); (5) SQLite (`.sqlite`, `.sqlite3`, `.db`, `.db3` + valid magic header); (6) local filesystem. Missing local paths attempt a **unique suffix match**: glob `**/<escaped-path>` from cwd, 5 s timeout (`GLOB_TIMEOUT_MS = 5000`), exactly 1 match required, notice prefix `[Path '<from>' not found; resolved to '<to>' via suffix match]`. `resolveReadPath` expands `~`, resolves against session cwd, maps bare `/` to cwd, has macOS fallbacks (NFD, curly quotes, screenshot timestamps).

**Local text read semantics**:
- No selector + parseable code → **structural summary** (tree-sitter `summarizeCode` from pi-natives): declarations kept, bodies elided with `…` or merged brace-pair lines `head { … } tail` (`canMergeBracePair`, read.ts:282); guard: size ≤ 2 MiB (`MAX_SUMMARY_BYTES`), ≤ 20 000 lines (`MAX_SUMMARY_LINES`); summary parse memoized per session (LRU 48). Footer when spans elided: `[…<N>ln elided; re-read needed ranges, e.g. <path>:5-16,40-80]` (up to `FOOTER_RANGE_SAMPLES = 2` sample ranges, read.ts:387).
- Selector/normal read → streaming line reader (`streamLinesFromFile`, 8 KiB chunks, read.ts:397-639): collects up to `maxLines` = min(`read.defaultLimit` setting, 3000), byte budget `max(50 KiB, maxLines*512)`; counts total file lines; reports `stoppedByByteLimit`, first-line preview for very wide first lines.
- Explicit bounded ranges expand context: `RANGE_LEADING_CONTEXT_LINES = 1`, `RANGE_TRAILING_CONTEXT_LINES = 3`, only on the constrained sides (read.ts:411-431). Raw mode never expands.
- Output prefixes: hashline mode → header `[<anchor>#TAG]` (anchor = basename for in-cwd files, `shortenPath` for absolute out-of-tree; `formatReadHashlineHeader`, read.ts:192) + `LINE:TEXT` rows; line-number mode → `LINE|TEXT`; raw → verbatim. Whole-file normalized text recorded into the snapshot store with the displayed line numbers as `seenLines`.
- Out-of-bounds line requests do not throw; they return explanatory text ("Use :1 ..." / "Use :<last line> ...").
- Per-line display column cap from `tools.outputMaxColumns`.

**Directories**: `buildDirectoryTree` with `maxDepth 2`, `perDirLimit 12`, sorted by recency, sizes and relative ages shown; empty → `(empty directory)`.

**Archives**: tar/tgz fully read into memory (cap `MAX_TAR_ARCHIVE_BYTES = 256 MiB`), indexed with `Bun.Archive`; zip via ranged central-directory reads + raw DEFLATE (`node:zlib`); member extraction cap `MAX_ARCHIVE_MEMBER_BYTES = 64 MiB`. Inner paths normalize `/`, drop `.`, reject `..`. Directory listing cap 500 entries. Non-UTF-8 member → text `[Cannot read binary archive entry '...' (...)]` (not an error).

**SQLite**: opened `{readonly: true, strict: true}`, `PRAGMA busy_timeout = 3000`. Selectors: bare file → table list (cap 500); `:table` → schema + 5 sample rows; `:table:key` → row by single-column PK else rowid; `:table?limit=&offset=&order=&where=` → query (default limit 20, max 500; `order` = `col[:asc|desc]` must exist; `where` validated to reject comments/semicolons/`LIMIT|OFFSET|UNION|ATTACH|PRAGMA`); `?q=SELECT…` raw query (no bound params, row cap `MAX_RAW_QUERY_ROWS = 1000`). Render caps: table width 120, column width 40.

**Documents**: `.pdf .doc .docx .ppt .pptx .xls .xlsx .rtf .epub` (read.ts:153) converted via markit to markdown; selectors apply to converted text. PDF embedded images become `read \`doc.pdf:p11-img0.png\`` handles (extracted once into an artifact cache dir). Conversion failure → text `[Cannot read .pdf file: ...]`.

**Notebooks**: `.ipynb` → editable `# %% [code] cell:N` text unless `:raw`.

**Images**: detection by content (`readImageMetadata`); max 20 MiB (`MAX_IMAGE_INPUT_BYTES`); if `inspect_image.enabled` → metadata text only (MIME/bytes/dimensions/channels/alpha + suggestion to call inspect_image); else `[text note, image block]`, auto-resized when `images.autoResize` (target ≤1568×1568, ≤500 KiB; WebP excluded for models that can't decode it). Oversize error: `Image file too large: <size> exceeds <max> limit.`

**URLs** (`src/tools/fetch.ts`): output header block `URL: ...\nContent-Type: ...\nMethod: ...\nNotes: ...\n\n---`; `method` records the winning render path (`json`, `feed`, `text`, `alternate-markdown`, `md-suffix`, `content-negotiation`, `image`, `markit`, `llms.txt`, `raw`, `raw-html`, `failed`). Shown output truncated to **300 lines / 50 KiB**; full body cached as artifact; line selectors paginate the cached body without refetching. Timeout family `fetch {20,1,45}` s. Non-ok HTTP is a `method: "failed"` result, not a throw.

**Details** (`ReadToolDetails`, read.ts:760): `kind?("file"|"url"), truncation?, isDirectory?, resolvedPath?, suffixResolution?{from,to}, url?, finalUrl?, contentType?, method?, notes?, meta?, displayContent?{text,startLine,lineNumbers?}, summary?{lines,elidedSpans,elidedLines}, conflictCount?, displayReadTargets?`. `displayContent` lets the TUI render with its own gutter (no re-parsing the prefixes).

**Cancellation**: plain local line reads and directory listings deliberately run without the abort signal (they're fast); URL/archive/sqlite/document/image/summary/suffix-glob paths honor it via `throwIfAborted`.

**Merge-conflict support**: `:conflicts` selector lists unresolved git conflict regions; each gets a stable id N usable by `write conflict://N` (see write).

---

## 3. bash

Source: `src/tools/bash.ts`, `src/exec/bash-executor.ts`, `src/tools/bash-interactive.ts`, `src/tools/bash-interceptor.ts`, `src/tools/bash-pty-selection.ts`. Docs: `docs/tools/bash.md`, `docs/bash-tool-runtime.md`. Prompt: `src/prompts/tools/bash.md`.

**Identity**: name `bash`, `strict: true`. Concurrency: `pty:true` → "exclusive", else "shared" (parallel non-pty calls allowed).

**Description sent to model** (templated on hasEval/hasGrep/hasRead/hasGlob/asyncEnabled/autoBackgroundEnabled): "Runs commands in the embedded shell — terminal ops: git, bun, cargo, python." + strong steering: shell is NOT full GNU Bash; use eval for scripting; `cwd` param instead of `cd dir && …`; `env: {NAME: …}` for multiline/quote-heavy values; `pty: true` only for commands needing a real terminal; parallel bash calls run concurrently — chain order-dependent commands with `&&`; NEVER `ls`/`find`/`grep`/`rg` (use read/glob/grep tools); stderr merged; long output truncated with FULL capture at `artifact://<id>`; async/timeout section when enabled ("`timeout` is seconds; ... clamped to 1..3600 ... `timeout: 0` only for commands that must run until completion"; "`async: true` defers only reporting — it does NOT extend a nonzero timeout"); auto-background note; output minimizer section.

**Input schema** (bash.ts:137-152):
- `command: string` — "command to execute"
- `env?: Record<string,string>` — "extra env vars"; keys must match `^[A-Za-z_][A-Za-z0-9_]*$` else `ToolError("Invalid bash env name: <key>")`
- `timeout?: number` — "timeout in seconds; 0 disables the command deadline; nonzero values are clamped to 1-3600"
- `cwd?: string` — "working directory" (resolved against session cwd; must exist and be a directory)
- `pty?: boolean` — "run in pty mode" (default false)
- `async?: boolean` — "run in background" (schema variant only present when `async.enabled`)

**Execution semantics**:
1. If `cwd` absent, a leading single-line `cd <path> && ...` is rewritten into structured `cwd` and stripped from `command`. No other command rewriting.
2. Interceptor (`bashInterceptor.enabled`): regex rules run against original and cd-stripped command; a rule blocks only when its suggested tool is in the active tool set; block throws `ToolError` with `Blocked: <rule.message>` + original command; invalid regexes silently skipped. Default rules (settings-schema): `cat|head|tail|less|more` → read; `grep|rg|ripgrep|ag|ack` → grep; `find|fd|locate` with name/type flags → glob; `sed -i|perl -i|awk -i inplace` → edit; `echo|printf|cat <<` + redirection → write.
3. Internal URL expansion (`expandInternalUrls`): rewrites `skill://` etc. inside `command` (shell-escaped), `env` values and protocol-like `cwd` (raw, `noEscape`); creates parent dirs for `local://` paths.
4. `gh issue|pr` mutating subcommands invalidate the github cache before running.
5. Timeout clamped 1..3600 s (default 300); clamp adds a notice line to the result.
6. Path selection: explicit `async: true` → managed background job, returns immediately. Else auto-background (`bash.autoBackground.enabled`, default threshold `DEFAULT_AUTO_BACKGROUND_THRESHOLD_MS = 60_000`, capped to `timeoutMs - 1000`): run as managed job, wait up to the window, convert to background if still running. Else client-terminal bridge (ACP editor terminal; signal kill maps to exit 137). Else PTY (`pty===true` && `PI_NO_PTY!=="1"` && UI available; otherwise falls back with notice `pty requested but unavailable in this environment; ran without a terminal`). Else non-PTY `executeBash()`.
7. **Non-PTY engine** (`bash-executor.ts`): persistent native `Shell` sessions cached process-globally keyed by (shell path, prefix, snapshot path, serialized env, session key, minimizer config). One command at a time per shell; overlapping calls on a busy key run one-shot `executeShell()`. Bash rc **snapshot** captures aliases/functions/options (best-effort). Optional configured `prefix` prepended: `<prefix> <command>`. Child env = non-interactive hardening layered under caller `env` (`buildNonInteractiveEnv`): `PAGER=cat`, `GIT_PAGER=cat`, `LESS=FRX`, `GIT_EDITOR=true`, `EDITOR=true`, `VISUAL=true`, `TERM=dumb`, `GIT_TERMINAL_PROMPT=0`, `SSH_ASKPASS=/usr/bin/false`, `NO_COLOR=1`, `CI=1`, package-manager non-interactive flags; Windows UTF-8 locale defaults. Host-side timer at `max(1000, timeoutMs)` aborts and **quarantines** the persistent shell; timeout/cancel come back as structured `cancelled: true` (no throw inside executor).
8. **PTY engine** (`bash-interactive.ts`): native `PtySession`, xterm-headless overlay titled `Console`, user key input forwarded, `Esc` kills, resize propagates. Inherits the user's environment with `TERM=xterm-256color` (no non-interactive hardening). Output normalized CRLF/CR→LF, sanitized, sent into `OutputSink`. PTY startup error → sink line `PTY error: ...`, undefined exit code.
9. Streaming: non-PTY foreground emits tail-only `onUpdate` snapshots via `TailBuffer(50 KiB)`; executor throttles `onChunk` at 50 ms.
10. **Output shaping**: stdout+stderr merged; empty → `(no output)`. Shell **minimizer** may rewrite verbose test/lint output to failures-only; original saved to a `bash-original` artifact referenced by `[raw output: artifact://<id>]` footer.
11. Result mapping: zero exit → success text; non-zero → `isError` result with output plus final line `Command exited with code <n>` and `details.exitCode`; missing exit code → thrown `ToolError("Command failed: missing exit status")`; timeout → thrown `ToolError` (PTY/client-terminal: `Command timed out after <n> seconds`); abort → `ToolAbortError`.
12. Background start text: optional preview tail + timeout notice + `Background job <id> started: <label>` with follow-up instructions; `details.async = { state: "running", jobId, type: "bash" }`. Completion delivered later through the async job manager (a non-zero exit records the job failed).

**Details**: `timeoutSeconds`, `requestedTimeoutSeconds?`, `wallTimeMs?`, `terminalId?`, `exitCode?`, `meta.truncation` (with `artifactId`), `async?`.

**TUI**: collapsed preview 10 visual lines (`BASH_DEFAULT_PREVIEW_LINES = 10`); expanded shows available (tail) text; warning line shows truncation reason + `artifact://<id>`; footer shows timeout. User `!` commands use a separate component (20-line collapsed preview, 4000-char line clamp).

Also present: `CRITICAL_BASH_PATTERNS` (bash.ts:84) — regex list flagging destructive shapes (rm -rf /, sudo rm, mkfs, dd to devices, fork bombs, curl|sh, shutdown/reboot, nc -e…) for approval policy escalation.

**Port notes**: Bun-specific — native `Shell`/`PtySession` from `@oh-my-pi/pi-natives` (Rust crate; portable-pty-style), `Bun.env`, `Bun.write`. Zig: std.process.Child with process groups for pipe mode; PTY via posix_openpt/forkpty on Linux/macOS and ConPTY on Windows; persistent-shell reuse is optional (one-shot spawn per call reproduces observable behavior minus rc snapshot cost); implement OutputSink (head/tail windows, UTF-8-safe trims, artifact spill) exactly.

---

## 4. edit

Source: `src/edit/index.ts` (EditTool), modes in `src/edit/modes/{replace,patch,apply-patch}.ts` + `src/edit/hashline/`, engine in `packages/hashline/src/*`. Prompt (default mode): `packages/hashline/src/prompt.md`. Doc: `docs/tools/edit.md`.

**Identity**: name `edit`, label `Edit`, essential, `concurrency: "exclusive"`, `strict: true`. Approval "write" (internal-URL targets → "read"). Approval detail line: `File: <path extracted from input>`.

**Mode selection** (`src/utils/edit-mode.ts`): per-model settings override → `PI_EDIT_VARIANT` env → `edit.mode` setting → default `"hashline"`. Modes: `hashline` (default), `replace`, `patch`, `apply_patch`. In hashline/apply_patch modes the tool exposes a Lark grammar via `customFormat` for constrained decoding; apply_patch also sets `customWireName: "apply_patch"`.

### 4.1 hashline mode (default) — full spec

**Schema**: `{ input: string }` (`src/edit/hashline/params.ts:8`; permissive, only `input` required).

**Description**: full text of `packages/hashline/src/prompt.md` (quoted extensively in §Prompt below). Key sentences: "Your patch language names lines to replace, delete, or insert at, then lists the new content. Rule of thumb: a header ending in `:` is followed by `+` body rows; `DEL` has no body." Sections: headers (`[PATH#TAG]`, TAG = 4-hex snapshot tag from latest read/search, REQUIRED — no hashless form; create files with `write`), ops, body rows, rules, examples, anti-patterns, and a `<critical>` triple: (1) RE-GROUND AFTER EVERY EDIT (fresh #TAG per apply), (2) RANGES ARE TIGHT, (3) THE BODY IS THE FINAL CONTENT.

**Patch language** (constants `packages/hashline/src/format.ts`): file header `[` path `#` TAG `]`; range separator `.=`; body sigil `+`; keywords `SWAP`, `DEL`, `INS` (+`.PRE/.POST/.HEAD/.TAIL`), block ops `SWAP.BLK`, `DEL.BLK`, `INS.BLK.POST`, file ops `REM` (delete file) and `MV DEST` (move/rename; line edits above `MV` apply first). Ops:
- `SWAP N.=M:` replace inclusive original lines N..M with body rows.
- `SWAP.BLK N:` replace the tree-sitter block beginning at line N (resolved at apply time; leading decorators/doc-comments are separate nodes — anchor the first decorator line; Markdown headings resolve whole sections).
- `DEL N.=M` / `DEL N` delete lines, no body. `DEL.BLK N` deletes the resolved block.
- `INS.PRE N:` / `INS.POST N:` insert before/after line N. `INS.BLK.POST N:` insert after the block's last line (unresolvable anchor is lowered to plain `INS.POST N:` with a warning — never a hard error).
- `INS.HEAD:` / `INS.TAIL:` insert at file start/end.
- Body rows: every row is `+TEXT` (verbatim, leading whitespace kept); bare `+` = blank line; no context/`-` rows exist; literal `-`/`+` lines are written `+- item` / `++ item`.

**Tag**: `computeFileHash(text)` (format.ts:112) = xxHash32(normalized text, seed 0) & 0xffff, upper-hex, 4 chars, zero-padded. Normalization for hashing strips trailing `[ \t\r]+` from every line (CRLF- and trailing-space-insensitive).

**Lenient parsing** (tokenizer/parser): `SWAP N:` ⇒ `SWAP N.=N:`; `DEL N`; missing trailing colon accepted; `SWAP N-M:` / `N…M` / `N M` / legacy `N..M` all ⇒ `N.=M`; bare body rows auto-prefixed `+` with `BARE_BODY_AUTO_PIPED_WARNING`; `*** Begin Patch`/`*** End Patch` envelope silently consumed; `*** Abort` stops parsing silently; empty `SWAP N.=M:` treated as `DEL N.=M`. Rejections with exact messages (docs/tools/edit.md:160-194): missing section header (`input must begin with "[PATH#HASH]" ...`); missing tag (`Missing hashline snapshot tag for <path>; use \`[<path>#tag]\` from your latest read/search output. To create a new file, use the write tool.`); stray payload (`line N: payload line has no preceding hunk header. ...`); minus rows (``line N: `-` rows are not valid; the range already names the lines being changed. ...``); empty INS/SWAP.BLK bodies; DEL with body; `range A.=B ends before it starts.`; overlapping hunks (`anchor line X is already targeted by another hunk on line Y. Issue ONE hunk per range; payload is only the final desired content, never a before/after pair.`); apply_patch sentinels and `@@` hunk headers rejected with steering text; bare `N M` headers rejected ("hunk headers need a verb"); out-of-range anchor (`Line N does not exist (file has M lines)`).

**Apply pipeline** (`packages/hashline/src/patcher.ts`): `Patcher.apply(patch)` — prepare every section fully in memory first (all-or-nothing preflight), then commit in order; duplicate canonical paths in one patch → error "Multiple hashline sections resolve to the same file...". Per-section `prepare`:
1. Parse; require tag.
2. Read file; if missing, **tag-based path recovery**: find snapshots with the same basename AND tag across all tracked paths (unique match only), rebind with warning `pathRecoveredFromTagMessage`; gated by `fs.allowTagPathRecovery` (refuses redirects outside cwd/sandbox). Still missing → `File not found: <path>. Use the write tool to create new files.`
3. Strip BOM, detect line ending, normalize to LF.
4. **Match algorithm** (`#applyWithRecovery`, patcher.ts:578):
   - If live content hashes to the tag (or no tag): resolve block edits against live text, then run the **seen-lines guard**: reject anchors on lines the read that minted the tag never displayed (`unseenLinesMessage`), inlining up to `SEEN_LINE_REVEAL_CAP = 40` actual lines (per-line cap `SEEN_LINE_REVEAL_MAX_COLUMNS = 512`); a full-width, complete reveal merges those lines into seenLines so a straight retry succeeds; then `applyEdits()`.
   - Stale tag + only HEAD/TAIL inserts (position-stable): apply onto live content with `HEADTAIL_DRIFT_WARNING`.
   - Stale tag + anchored edits: **recovery** (`recovery.ts`), three strategies in order: (1) apply edits to the tagged snapshot text, `Diff.structuredPatch` (context 3) then `Diff.applyPatch(current, patch, { fuzzFactor: 0 })` — `RECOVERY_FUZZ_FACTOR = 0`, exact alignment only (warning `RECOVERY_EXTERNAL_WARNING` when tag = head snapshot, else `RECOVERY_SESSION_CHAIN_WARNING`); (2) line-remap: diff unchanged lines snapshot→live, remap every anchor through the map, require one consistent nonzero offset and validated neighbor context (duplicate-line safe), replay on live (`RECOVERY_LINE_REMAP_WARNING`); (3) session-chain replay (non-head snapshot only): replay original line numbers onto live when line counts are equal AND every anchor line's content is identical (`RECOVERY_SESSION_REPLAY_WARNING`). All failing → `MismatchError` distinguishing recognized-but-drifted vs never-recorded hashes, with 2 context lines around each anchor (`MISMATCH_CONTEXT = 2`).
5. `applyEdits` (apply.ts, pure): validates bounds, buckets by anchor, includes a heuristic **boundary-echo repair**: a multi-line SWAP whose payload restates the line just past the range (off-by-one keeper, detected with delimiter-balance analysis incl. JSX) is auto-trimmed with a warning.
6. Commit: restore BOM + original line endings, write via Filesystem (LSP writethrough: format-on-write + diagnostics), record fresh snapshot, return `[path#NEWTAG]` header.

**No-op handling**: byte-identical result → soft text: `Edits to <path> parsed and applied cleanly, but produced no change: your body row(s) are byte-identical ... re-read the file before issuing another edit. Do NOT widen the payload...`; after `NOOP_HARD_LIMIT = 3` consecutive identical no-ops (per file, per payload; `src/edit/hashline/noop-loop-guard.ts`), escalates to thrown `ToolError` (`STOP. Edits to <path> have been a byte-identical no-op N times in a row …`).

**Output**: single text block: post-edit `[path#TAG]` header (fresh tag), block-op resolution echoes (`SWAP.BLK N → resolved lines A-B (K lines)`; INS.BLK.POST appends `; body lands after line B`), compact diff preview (`packages/hashline/src/diff-preview.ts`), then `Warnings:` block when any. Multi-file inputs aggregate; on a mid-batch failure the text lists `Files already applied: …` / `Files NOT applied: …; re-read the affected files and re-issue only the failed and unapplied files.` and the aggregate is `isError`.

**Details** (`EditToolDetails`): `diff` (unified), `firstChangedLine`, `diagnostics` (LSP), `op: "create"|"update"` (also delete/move), `move?`, `meta`, `perFileResults?`, `oldText`/`newText` snapshots (pruned when oversized; `snapshotsPruned` marker). TUI renders the diff (collapsed 8 hunks / 40 lines).

### 4.2 replace mode
Schema (`modes/replace.ts:1015`): `{ path: string, edits: Array<{ old_text: string, new_text: string, all?: boolean }> }`. Description (`prompts/tools/replace.md`): "Performs string replacements in files with fuzzy whitespace matching." — smallest unique `old_text`; expand or `all: true` on multiple matches; must read file before editing.
Matching pipeline: progressive strategies `exact → trim-trailing → trim → comment-prefix → unicode → prefix → substring → fuzzy → fuzzy-dominant → character` (`SequenceMatchStrategy`, replace.ts:46); fuzziness gated by `edit.fuzzyMatch` setting / `PI_EDIT_FUZZY` env, threshold `edit.fuzzyThreshold` / `PI_EDIT_FUZZY_THRESHOLD` (0..1). Not-found / ambiguous produce `EditMatchError` with closest-match preview and occurrence lines. Entries apply sequentially; first failure stops with `Error editing <path> (entry i of n): …` + `Entries 1-i were already applied.` / `Entries i+2-n were NOT applied…` (index.ts:293).

### 4.3 patch mode
Schema (`modes/patch.ts:1668`): `{ path: string, edits: Array<{ op?: "create"|"delete"|"update", rename?: string, diff?: string }> }`, diff is a context-anchored `@@`-header format (examples in index.ts:487-519). `op:"create"` doubles as full-file overwrite. Fuzzy context matching shares the replace-mode machinery.

### 4.4 apply_patch mode
Schema: `{ input: string }` — full Codex `*** Begin Patch / *** Add File: / *** Update File: (+ *** Move to:) / *** Delete File: / *** End Patch` envelope; parsed then lowered to patch entries per file (modes/apply-patch.ts:16). Empty patch → `ApplyPatchError("No files were modified.")`. Multi-file semantics identical to §4.1 aggregation. Lark grammar exposed for constrained decoding.

Related: `packages/typescript-edit-benchmark` is a mutation-based benchmark suite for these edit modes (fixtures + `all_models_results.json`); useful for validating a port's matcher against recorded model behavior, not part of the runtime.

---

## 5. write

Source: `src/tools/write.ts`. Prompt: `src/prompts/tools/write.md`. Doc: `docs/tools/write.md`.

**Identity**: name `write`, essential, `concurrency: "exclusive"`. Schema (write.ts:109): `{ path: string /* "file path" */, content: string /* "file content" */ }`.

**Description**: "Creates or overwrites file at specified path." Conditions: new files explicitly required; replacing entire contents when editing would be more complex; archive entries via `archive.ext:path/inside/archive`; SQLite rows via `db.sqlite:table` (insert) / `db.sqlite:table:key` (update w/ JSON, delete w/ empty). Critical: SHOULD use Edit for modifying existing files; NEVER create docs (`*.md`, README) unless requested; NEVER emojis unless requested.

**Semantics** (dispatch order):
1. In hashline display mode, pasted `[PATH#HASH]` headers and `LINE:` prefixes are stripped from `content` (with a note in the result).
2. Internal URL with a writable handler → delegate; result `Successfully wrote <chars> bytes to <url>`.
3. `conflict://<id>` → splice the recorded merge-conflict region with `content`; `conflict://*` bulk-resolves; scope reads (`conflict://<id>/ours`) rejected as read-only.
4. Archive selector (`.tar/.tar.gz/.tgz/.zip:inner/path`): parent dir of the archive created (`fs.mkdir recursive`); zip is unzipped to a map, entry replaced, re-zipped; tar via Bun.Archive rewrite; result `Successfully wrote <chars> bytes to <archive>:<entry>`; errors `Archive write path must target a file inside the archive`, `... not a directory`, `Archive path cannot contain '..'`.
5. SQLite selector (DB must already exist; `{create:false, strict:true}`, busy_timeout 3000): `:table` + JSON5 object → insert (`{}` ⇒ `INSERT INTO t DEFAULT VALUES`); `:table:key` + content → update; `:table:key` + empty/whitespace content → delete. Results `Inserted row into <t>` / `Updated row '<k>' in <t>` / `No row updated ...` / `Deleted row ...` / `No row deleted ...`. Errors: `SQLite database '<path>' not found`, `SQLite write paths do not support query parameters`, `SQLite write path must target a table`, `SQLite row writes require a non-empty row key`, invalid JSON5 / non-object / unknown columns / non-scalar values / composite PK / WITHOUT ROWID rejections.
6. Plain file: plan-mode write guard; existing files checked by the auto-generated-file guard (`assertEditableFile`, reads ≤1024 bytes / 40 header lines for "generated" markers); write goes through ACP bridge when available, else LSP writethrough (format-on-write, diagnostics; 5000 ms op timeout, deferred diagnostics fetch `AbortSignal.timeout(25_000)`) else direct write (`Bun.write` creates parent dirs). Shebang content (`#!`) may chmod the file executable (`details.madeExecutable`). FS-scan caches invalidated.
7. Result: `Successfully wrote <chars> bytes to <relative-path>` (note: `chars` is UTF-16 code-unit length, not disk bytes). In hashline mode, plain-file writes and conflict resolutions prepend a fresh `[<relative-path>#TAG]` header so the next edit needs no re-read; bulk conflicts append a `Snapshots:` block.

**Details**: `diagnostics?`, `meta.diagnostics?`, `madeExecutable?`, archive `resolvedPath?`, SQLite `meta.sourcePath`.

---

## 6. grep

Source: `src/tools/grep.ts`, native `crates/pi-natives/src/grep.rs`. Prompt: `src/prompts/tools/grep.md`. Doc: `docs/tools/grep.md`.

**Description**: "Greps files using regex." Instructions: Rust regex/PCRE2 syntax; scope `path` (semicolon-delimited list allowed); `selector` for line filtering only; cross-line patterns detected from literal `\n`/`\\n`. Output note (hashline): "Per matched file: snapshot tag header + numbered lines: `[src/login.ts#1A2B]`, `*42:if (user.id) {` (match), ` 43:return user;` (context)." Critical: MUST use built-in grep for any content search — never shell out; open-ended multi-round search → Task/scout.

**Wire schema** (grep.ts:77):
- `pattern: string` — "regex pattern" (whitespace-only rejected: `Pattern must not be empty`; otherwise verbatim)
- `path?: string` — 'file, directory, glob, internal URL, or "<file>:<lines>" selector to search; pass several as a semicolon-delimited list ("src; tests"). Omitted -> searches the workspace root (".")'
- `selector?: string` — 'line selector applied to every searched file (e.g. "50-100", "50+10", "50-100,200-300"); never a path like "/"'
- `case?: boolean` — "case-sensitive search" (default true)
- `gitignore?: boolean` — "respect gitignore" (default true; directory traversal only)
- `skip?: number | null` — "files to skip before collecting results — use to paginate when the prior call hit the file limit" (default 0; floored; negative/non-finite → `Skip must be a non-negative number`)

**Semantics**: multiline enabled only when pattern contains `\n` or literal newline. Delimiter-flattened entries expanded only after existence validation (comma/semicolon: ≥1 part must resolve; whitespace: all parts must resolve). Archive members (`bundle.zip:src/foo.ts`) are extracted to scratch files for native grep (UTF-8 only). Internal URLs: glob metachars rejected; backed resources search their sourcePath; virtual resources searched in-JS with `RegExp` (`Invalid regex: ...` on compile failure); `omp://` expands to all embedded docs. Missing entries in multi-path calls skipped unless all missing (`Path not found: ...; pass each path as its own array element`). Line-range selectors valid only for single files/archive members/virtual resources (`Line-range selector requires a single file, not a glob: ...` etc.).

Native call parameters: `hidden: true` (hard-coded), `cache: false`, `contextBefore`/`contextAfter` from settings (defaults **1 before / 3 after**), `maxColumns: 512`, `maxCount: 2000` (`INTERNAL_TOTAL_CAP`), `maxCountPerFile: per-file cap + 1`, `timeoutMs: 30_000` (`SEARCH_GREP_TIMEOUT_MS`), abort signal. Native matcher auto-escapes braces that can't be quantifiers (so `${platform}` works) and retries with escaped parentheses on unopened/unclosed-group compile errors. Per-file native size cap 4 MiB — oversized files silently skipped, surfaced as a `Skipped oversized file(s)` note. Timeout error: ``Grep timed out after 30s; narrow paths or pattern, or scope with `glob` first``.

**Output**: per-file `[PATH#TAG]` header (whole-file snapshot recorded for editable files) + `*LINE:content` for matches, ` LINE:content` for context (plain mode `*LINE|content`). Multi-file results grouped as a prefix-folded directory tree (`#` per level, dirs end `/`). Caps: 20 files/page (`DEFAULT_FILE_LIMIT`) with `Use skip=<N> for the next page`; matches/file: 20 multi-file (`MULTI_FILE_PER_FILE_MATCHES`), 200 single-file (`SINGLE_FILE_MATCHES`); round-robin selection across files; per-line 512-char cap with `…`; final text `truncateHead(maxLines=∞)` ⇒ effective 50 KiB byte cap. No matches → `No matches found` (or `No more results (...)` past the last page) + skipped-path/oversize notes. Details: `scopePath, matchCount, fileCount, files, fileMatches, fileLimitReached, perFileLimitReached, linesTruncated, truncated, meta.truncation, displayContent, missingPaths`.

---

## 7. glob

Source: `src/tools/glob.ts`. Prompt: `src/prompts/tools/glob.md`. Doc: `docs/tools/glob.md`.

**Description**: "Globs files and directories via fast pattern matching, any codebase size." — `path` may be a semicolon-delimited list; `gitignore` default true (set false to find ignored files); `hidden` default true; output "Matching paths sorted by mtime (newest first), grouped under `# <dir>/` headers with basenames below; directories get a trailing `/`." Avoid: multi-round open-ended searches → Task.

**Wire schema** (glob.ts:41):
- `path?: string` — 'glob, file, or directory to search — a single path or a semicolon-delimited list ("src/**/*.ts; test/**/*.ts"). Omitted -> searches the workspace root (".")'
- `hidden?: boolean` — "include hidden files" (default true)
- `gitignore?: boolean` — "respect gitignore" (default true)
- `limit?: number` — "max results" (default 200 = `DEFAULT_LIMIT`, floored, clamped 1..200 = `MAX_LIMIT`; non-positive → `Limit must be a positive number`)

**Semantics**: `parseFindPattern`: no glob chars → path + implicit `**/*`; glob in first segment → base `.` and prefix `**/` unless already `**/`; glob later → split at first glob segment. `resolveToCwd`; `/` root rejected: `Searching from root directory '/' is not allowed`. Fixed internal timeout 5000 ms — timeout returns a **successful partial** result text `glob timed out after <s>s; returning <N> partial matches — narrow the pattern instead of retrying blindly`. Exact-file inputs short-circuit. Native glob invoked with `hidden`, `maxResults: limit`, `sortByMtime: true`, `gitignore`, `recursive: false` (recursion from the `**/` prefix); multi-entry lists run per-root concurrently, merged, deduped, re-sorted by mtime desc. Streaming: newline-delimited snapshot every 200 ms via `onUpdate`. Missing multi-path entries → `Skipped missing paths: ...` + `details.missingPaths`; all missing → `Path not found: ...`. Empty result → `No files found matching pattern`. Output byte cap 50 KiB (maxLines overridden to ∞). Details: `scopePath, fileCount, files, truncated, resultLimitReached, missingPaths, truncation, meta.limits`.

---

## 8. todo

Source: `src/tools/todo.ts`. Prompt: `src/prompts/tools/todo.md`. Doc: `docs/tools/todo.md`.

**Identity**: `concurrency: "exclusive"`, `strict: true`, discoverable. Gated by `todo.enabled` and absence of yield tool; subagents never inherit it.

**Description** highlights: tasks referenced by verbatim content string, NEVER `task-N` ids; on each completion the earliest still-open task auto-promotes to `in_progress`; ops table; anatomy (task content 5–10 words, unique; phase = short noun phrase, no `1.`/`Phase 1:` prefixes); rules (mark done immediately, complete phases in order, `view` if text lost); when to create (3+ steps, user request, user-provided list, mid-task instructions); critical: given a multi-step plan, MUST `init` with EVERY item.

**Schema** (todo.ts:52-68) — one flat op per call:
- `op: "init"|"start"|"done"|"rm"|"drop"|"append"|"view"` — "operation to apply"
- `list?: Array<{ phase: string, items: string[] (minItems 1) }>` — "phased task list (init)"
- `task?: string` — "task content"
- `phase?: string` — "phase name"
- `items?: string[]` — "tasks to append" (also flat-init payload; `init` with `items` synthesizes one phase, default name `Tasks`)

**State model**: `TodoPhase { name, tasks: TodoItem[] }`, `TodoItem { content, status: "pending"|"in_progress"|"completed"|"abandoned" }`. Op semantics: `init` replaces everything; `start` sets one task `in_progress`, demotes other actives to `pending`; `done`/`drop`/`rm` target one task (exact content match), one phase, or everything when both omitted; `append` pushes pending tasks, lazily creates phase, rejects globally duplicate content (`Task "..." already exists`); `view` read-only. Post-op normalization: only first `in_progress` survives; if none, first pending auto-promotes. Errors accumulate as strings (`Missing list for init operation`, `Task "..." not found`, `Phase "..." not found`, `Duplicate phase/task "..." in init list`, `Missing items for append operation`, …); any error → `isError: true` and the whole mutation is **discarded** (state stays pre-call).

**Output**: `formatSummary` text — empty state → `Todo list cleared.` (`Todo list is empty.` for pure view); otherwise remaining count, phase progress, per-phase tree; errors prefix `Errors: ...`. Details: `{ phases, storage: "session"|"memory", completedTasks? }`. TUI merges call+result, renders phase tree, collapsed cap 8 items; visible-panel auto-clear of closed entries after `tasks.todoClearDelay` (default 60 s, display-only). Failed todo results trigger a hidden next-turn reminder (`customType: "todo-error-reminder"`).

---

## 9. task (subagents)

Source: `src/task/index.ts` etc. Doc: `docs/tools/task.md` (deep). Prompt: `src/prompts/tools/task.md` (dynamic: includes discovered agent catalog).

**Schema** shape-swapped by `task.batch` (default **on**): batch `{ context: string (required, shared background), tasks: Array<{ name?, agent?, task (required), isolated? }> }`; flat (batch off) `{ name?, agent?, task, isolated? }`. `isolated` exists only when `task.isolation.mode !== "none"`. No `schema` param (always rejected); no label param (labels are generated by a tiny model).

**Semantics**: items with agent `blocking: true` (e.g. `scout`) run inline; others become `type:"task"` async jobs when `async.enabled`. Session-scoped semaphore sized from `task.maxConcurrency`. Agent sources first-wins: project `.omp` agents → user `.omp` → plugin dirs → bundled (`scout, designer, reviewer, task, sonic, librarian`). Children: no conversation history inheritance; carry-over is workspace tree/skills/context files, shared `local://` root, approved plan; child settings force `async.enabled=false` and `bash.autoBackground.enabled=false`; `todo` stripped; `task` stripped at max depth; `irc` ensured. Child must finish via hidden `yield` tool — up to `MAX_YIELD_RETRIES = 3` reminders, last forcing toolChoice; failure text `SYSTEM WARNING: Subagent exited without calling yield tool after 3 reminders.` Output caps: `MAX_OUTPUT_BYTES = 500_000`, `MAX_OUTPUT_LINES = 5000` (env-overridable); progress coalescing 150 ms; recent-output tail 8 KiB; inline summary preview 5000 chars, full output at `agent://<id>`; per-spawn budgets `task.softRequestBudget`, `task.maxRuntimeMs`; idle TTL `task.agentIdleTtlMs` default 420 000 ms then parked (revivable via irc/hub; `history://<id>` transcripts). Isolation via natives PAL: overlayfs/APFS/Btrfs/ZFS/reflink/ProjFS/rcopy; merge as patch or branch `omp/task/<id>`. Background return text: `` Spawned agent `<id>` (job `<jobId>`). The result will be delivered when it yields. `` (batch: `Spawned N background agents using <types>.` + per-agent lines).

---

## 10. eval

Source: `src/tools/eval.ts` + `src/eval/*`. Doc: `docs/tools/eval.md`.

**Schema**: `{ cells: EvalCellInput[] (min 1) }`, cell = `{ language: "py"|"js" (also ruby/julia backends exist behind settings), code: string, title?: string, timeout?: int (1..3600, default 30), reset?: boolean }`. Cells run in order; state persists per language across cells and calls (subagents inherit the parent's eval session id).

**Semantics**: explicit backend per cell, no sniffing; unavailable backend → ToolError. Timeout is a runtime-work budget (IdleTimeout paused during host-side agent()/completion() bridge calls). JS backend: persistent worker VM keyed `js:<sessionId>`; top-level await/return wrapped in async IIFE; imports rewritten through `__omp_import__` with local-module cache-busting; prelude globals `display, print, console, read, write, env, output, tool.<name>(), completion(), agent(), parallel(), pipeline(), log(), phase(), budget`. Python: IPython-style subprocess kernel (NDJSON runner protocol, `docs/python-repl.md`). Output: combined cell text (multi-cell prefixed `[i/n]` + title), `(no output)` / `(displayed N image(s); no text output)`; image blocks appended; details `cells[] (code, status pending/running/complete/error, output, duration, exitCode), language, languages, jsonOutputs, statusEvents, meta, isError`. First cell error skips later cells (state persists). OutputSink + artifact spill as bash.

---

## 11. ssh

Source: `src/tools/ssh.ts`. Doc: `docs/tools/ssh.md`.

**Schema**: `{ host: string (config key from discovered hosts, not arbitrary), command: string, cwd?: string, timeout?: number (default 60, clamp 1..3600) }`. Tool not registered when discovery finds no hosts (config sources: project `.omp/ssh.json`, user `~/.omp/agent/ssh.json`, repo `ssh.json`/`.ssh.json`; **not** `~/.ssh/config`). Description appends `Available hosts:` list with detected shell/OS.

**Semantics**: SSH master connection reuse (`ControlPersist=3600`, `StrictHostKeyChecking=accept-new`, `BatchMode=yes`); host OS/shell probed and cached (`HOST_INFO_VERSION = 2`); optional opportunistic sshfs mount (failures ignored). cwd wrapper: POSIX `cd -- '<cwd>' && cmd`; PowerShell `Set-Location -Path '<cwd>'; cmd`; cmd.exe `cd /d "<cwd>" && cmd`; Windows compat wraps in `bash -c`/`sh -c`. No PTY. stdout+stderr merged into OutputSink (50 KiB tail, artifact spill); tail streaming via onUpdate. Non-zero exit → ToolError with output + `Command exited with code N`; timeout/abort → cancelled notice (`[SSH: ...]` / `[Command aborted: ...]`) then ToolError. Errors: `Unknown SSH host: ... Available hosts: ...`, `ssh binary not found on PATH`, key validation (`SSH key permissions must be 600 or stricter: ...`), `Failed to start SSH master for <target>: <stderr>`. Exclusive concurrency. Also note the read/write/grep tools accept `ssh://host/<abs-path>` for remote file read (UTF-8 ≤ 1 MiB)/write/search on POSIX-shell hosts.

---

## 12. job

Source: `src/tools/job.ts`. Doc: `docs/tools/job.md`.

**Schema**: `{ poll?: string[], cancel?: string[], list?: boolean }`. `list` cannot combine with poll/cancel (ToolError). No args = watch all running jobs owned by the calling agent.

**Semantics**: cancels first (`not_found` / `already_completed` / `cancelled` receipts), then polls: waits on `Promise.race` of watched job promises + poll window + abort. Poll window: `async.pollWaitDuration` ∈ {5s,10s,30s,1m,5m,smart}, default `smart` = adaptive ladder [5s,10s,30s,1m,5m] climbing per back-to-back poll, resetting after 60 s idle. Progress `onUpdate` every 500 ms. Waits for **first** settle, not all. Watching suppresses automatic completion delivery; returning acknowledges deliveries for settled jobs. Output text sections `## Cancelled (N)` / `## Completed (N)` (with resultText/errorText) / `## Still Running (N)`. Details: `jobs[] { id, type: "bash"|"task", status: running|completed|failed|cancelled, label, durationMs, resultText?, errorText? }`, `cancelled?[]`. Manager caps: retention 5 min, max running 15 default (session clamps `async.maxJobs` 1..100). Timeout is a normal snapshot, not an error. Disabled-manager path returns text `Async execution is disabled; no background jobs are available.`

---

## 13. checkpoint / rewind

Source: `src/tools/checkpoint.ts`. Docs: `docs/tools/checkpoint.md`, `docs/tools/rewind.md`. Gated by `checkpoint.enabled` (default false); top-level sessions only.

- `checkpoint { goal: string }` → text `Checkpoint created.\nGoal: <goal>\nRun your investigation, then call rewind with a concise report.`; details `{ goal, startedAt }`. AgentSession then captures `{ checkpointMessageCount, checkpointEntryId, startedAt }` in memory. Errors: `Checkpoint not available in subagents.`, `Checkpoint already active.` NOT a git/FS snapshot — conversation-only. Yield while active injects `<system-warning>` forcing rewind first.
- `rewind { report: string }` (trimmed non-empty; `Report cannot be empty.`, `No active checkpoint.`) → text `Rewind requested.\nReport captured for context replacement.`; details `{ report, rewound: true }`. Actual rewind applies at `turn_end`: truncate in-memory messages to checkpoint count, branch persisted session tree with a `branch_summary` entry carrying the report, append hidden `rewind-report` custom message. Missing entry id → branch from root with a logged warning. Never restores files/git/artifacts.

---

## 14. ast_grep / ast_edit

Docs: `docs/tools/ast-grep.md`, `docs/tools/ast-edit.md`. Native engine `crates/pi-natives/src/ast.rs` (ast-grep + tree-sitter).

- `ast_grep { pat: string, paths: string[], skip?: number }`. Pattern grammar: `$NAME`, `$_`, `$$$NAME`, `$$$` (uppercase metavars, whole AST nodes, repeated var ⇒ identical code). ~57 languages (incl. zig). Output: hashline `*LINE:text` under `[PATH#TAG]`; `meta: NAME=value` lines for captures; visible cap `DEFAULT_AST_LIMIT = 50` (`Result limit reached; narrow paths or increase limit.`); parse issues deduped, cap 20; no matches → `No matches found` (+ parse-issue caveat text). Directory scans: hidden included, gitignore on, node_modules skipped unless glob names it.
- `ast_edit { ops: Array<{ pat, out }>, paths: string[] }` — empty `out` deletes node; duplicate `pat`s rejected. Always **preview-first**: dry-run result shows `-LINE:before` / `+LINE:after` pairs (first line only, 120-char cap), then queues a pending action; the model must call hidden `resolve {action:"apply"|"discard"}`. Apply reruns with `dryRun:false`, validates preview parity by totals/per-file counts (stale ⇒ error result), returns `Applied N replacements in M files.` (+ fresh `[path#tag]` headers in hashline mode). File cap `PI_MAX_AST_FILES` default 1000. Native applies edits back-to-front per file after overlap check (`Overlapping replacements detected; refine pattern to avoid ambiguous edits`); one language must be inferable across all candidates.

---

## 15. Other built-ins (summary specs)

- **ask** (`src/tools/ask.ts`): `{ questions: Array<{ id, question, options: Array<{label, description?}>, multi?, recommended? }> }` (min 1). UI-only (`hasUI`); exclusive. Single/multi select with auto-appended `Other (type your own)`; multi-question back/forward nav; `ask.timeout` seconds (0 = off, disabled in plan mode) auto-selects recommended/first with ` (auto-selected after timeout)`; cancel → `ToolAbortError("Ask tool was cancelled by the user")`. Text: `User selected: ...` / `User provided custom input: ...` / `User answers:` lines. Details flat for one question or `{ results: [...] }`.
- **web_search** (`src/web/search/index.ts`): `{ query, recency?("day"|"week"|"month"|"year"), limit?, max_tokens?, temperature?, num_search_results? }`. Sequential provider fallback over a 25-provider chain (perplexity → gemini → anthropic → codex → xai → zai → exa → tinyfish → jina → kagi → tavily → firecrawl → brave → kimi → parallel → synthetic → searxng → duckduckgo → bing → yahoo → startpage → google → ecosia → mojeek → public); output = answer + `## Sources` (`[n] title (age)` + url + 240-char snippet) + `## Citations` + `## Related` + `Search queries:`. Failures return `Error: ...` text (not thrown), `All web search providers failed: ...` when multiple attempted.
- **github** (`src/tools/gh.ts`): op-dispatched `gh` CLI wrapper: `repo_view, pr_create, pr_checkout, pr_push, search_issues, search_prs, search_code, search_commits, search_repos, run_watch` with fields per op (title/body/base/head/draft/fill/reviewer/assignee/label; query/since/until/dateField/limit ≤ 50 default 10; run/tail ≤ 200 default 15). Issue/PR reads go through `issue://` / `pr://` internal URLs backed by a SQLite cache (soft TTL 5 min, hard 7 d).
- **lsp** (`src/lsp`): `{ action ∈ diagnostics|definition|references|hover|symbols|rename|rename_file|code_actions|type_definition|implementation|status|reload|capabilities|request, file?, line? (1-indexed), symbol? (substring + `name#N` occurrence selector), query?, new_name?, apply?, timeout? (5..60, default 20), payload? }`.
- **inspect_image** (`src/tools/inspect-image.ts`): `{ path, question }` → sends [image, question] to a vision model (role `pi/vision` → `pi/default` → active → first); PNG/JPEG/GIF/WEBP by content sniffing; 20 MiB cap; auto-resize 1568×1568/500 KiB, quality ladder [70,60,50,40], scale ladder [1.0,.75,.5,.35,.25]. Returns model text; details `{ model, imagePath, mimeType }`.
- **search_tool_bm25** (`src/tools/search-tool-bm25.ts`): `{ query, limit? (default 8) }`; BM25+ (k1 1.2, b 0.75, δ 1.0) over hidden tools; field weights name 6 / label 4 / mcpToolName 4 / serverName 2 / summary 2 / schemaKey 1; activates matches into the session; content is compact JSON `{"query","activated_tools","match_count","total_tools"}`.
- **memory tools**: `retain { items: [{content, context?}] }`, `recall { query }`, `reflect { query, context? }` (hindsight/mnemopi backends), `memory_edit { op: update|forget|invalidate, id, content?, importance? (0..1), replacement_id? }` (mnemopi only). `learn { memory, context?, skill?{action,name,description,body} }` and `manage_skill { action: create|update|delete, name (kebab, ≤64), description, body }` write managed skills under `~/.omp/agent/managed-skills/<name>/SKILL.md`, 64 000-byte cap, never shadow authored skills.
- **irc** (`src/tools/irc.ts`): `{ op: send|wait|inbox|list, to?, message?, replyTo?, await?, from?, timeoutMs?, peek? }`. Process-global mailbox bus, 100-message mailbox cap, default timeout `irc.timeoutMs` = 120 000 (0 = infinite). Send receipts `injected|woken|revived|failed`; parked agents revived on direct send; broadcast (`to:"all"`) hits live peers only. Errors are `isError` text results, not throws.
- **browser** (`src/tools/browser.ts`): `{ action: open|close|run, name? ("main"), timeout? (default 30, clamp 1..300), url?, viewport?, wait_until?, dialogs?, app?{path|cdp_url|args|target}, all?, kill?, code? }`; `run.code` is an async JS body with `page/browser/tab/assert/wait` + the eval prelude, driving Puppeteer (headless, spawned app, or CDP attach; cmux backend when available).
- **debug** (`src/tools/debug.ts`): DAP client; `action` ∈ 27 values (launch/attach/breakpoints incl. instruction+data/continue/step/*, evaluate, stack_trace, threads, scopes, variables, disassemble, read_memory, write_memory, modules, loaded_sources, custom_request, output, terminate, sessions) with per-action required fields; timeout default 30 clamp 5..300.
- **tts** (`src/tools/tts.ts`, `speechgen.enabled`): `{ text (1..15000), voice_id? ("eve"), language? ("en"), output_path, sample_rate?, bit_rate? }`; local Kokoro-82M ONNX (WAV) or xAI Grok Voice (MP3/WAV).
- **generate_image** (`src/tools/image-gen.ts`, custom tool): `{ subject, action?, scene?, composition?, lighting?, style?, text?, changes?[], aspect_ratio?, image_size?, input?[{path|data,mime_type}] }`; provider dispatch OpenAI/Antigravity/OpenRouter/xAI/Gemini; input cap 35 MiB; 3-min provider timeout.
- **Hidden**: `yield` (subagent structured completion; enforced by up to 3 reminders), `resolve { action: "apply"|"discard", reason: string, extra? }` (finalizes pending previews — ast_edit, plan mode; apply with nothing pending → `ToolError("No pending action to resolve. Nothing to apply or discard.")`, discard with nothing pending succeeds with `Nothing to discard; no pending action remains.`; pending previews ride a non-forcing SoftToolRequirement reminder: `<system-reminder>\nThis is a preview. Call the `resolve` tool to apply or discard these changes.\n</system-reminder>`), `report_finding` (code-review findings), `report_tool_issue` (auto-QA), `goal` (goal mode).

---

## 16. Bun-specific surfaces → Zig equivalents

| Upstream dependency | Where | Zig port approach |
| --- | --- | --- |
| `Bun.hash.xxHash32` | hashline tag (`format.ts:114`) | xxHash32 (std or vendored); must match seed 0, low 16 bits, upper-hex 4 chars for transcript compatibility |
| `Bun.file`/`Bun.write` (auto parent-dir creation) | read/write/edit | std.fs; replicate parent-dir creation on plain writes |
| `bun:sqlite` | read/write SQLite modes, github cache | zig-sqlite/C sqlite3; keep `readonly/strict`, busy_timeout 3000, caps |
| `Bun.Archive` (tar), `node:zlib` raw DEFLATE (zip) | read/write archives | std.tar + a zip reader/writer w/ raw DEFLATE (std.compress.flate); 256 MiB tar cap, 64 MiB member cap |
| `Bun.JSON5.parse` | write SQLite row payloads | small JSON5 parser (or restrict to JSON + document divergence) |
| native `Shell`/`executeShell` (pi-natives Rust) | bash non-PTY | std.process.Child (`sh -c` / configured shell), non-interactive env table, kill-on-timeout, exit-code mapping |
| native `PtySession` + xterm-headless overlay | bash pty mode | Linux/macOS: openpty+fork, TERM=xterm-256color, ZigZag overlay for the console; Windows: ConPTY |
| `node-pty`-style client-terminal ACP bridge | bash | optional; skip initially |
| native `grep`/`glob`/`astGrep`/`summarizeCode` (Rust, ripgrep-like + tree-sitter) | grep/glob/read summaries/ast tools | Zig regex + dir walker with gitignore; tree-sitter C library for summaries/block ops (or defer structural summary + `*.BLK` ops, falling back to plain ops — the grammar already defines plain-op fallbacks) |
| `jsdiff` (`Diff.structuredPatch/applyPatch/diffArrays`) | hashline recovery, diff previews | port Myers diff + unified-patch apply with fuzzFactor 0 semantics |
| `lru-cache` | snapshot store, summary memo | simple bounded LRU |
| arktype schemas | all tool params | comptime Zig schema → JSON Schema for the wire; keep field names/optionality/defaults exactly as specced above |
| markit (document conversion), Puppeteer, DAP adapters, ONNX TTS | read documents, browser, debug, tts | out of scope for MVP; degrade to explicit "unsupported" errors |
| QuickJS (replaces eval JS/py backends per port plan) | eval | map `cells[]` schema onto zig-quickjs-ng contexts keyed by session; implement `display/read/write/env/tool()` prelude natively |

**Minimum-fidelity core for the port** (what the model actually depends on): the six essential tools (`read`, `bash`, `edit`(hashline), `write`, `glob`, `eval`) plus `grep` and `todo`, with byte-exact: hashline tag algorithm, `[path#TAG]` + `LINE:TEXT` read format, `*LINE:` grep match format, the truncation-notice strings, the bash `(no output)` / `Command exited with code <n>` conventions, and the edit-tool error strings (models are steered by these exact texts).
