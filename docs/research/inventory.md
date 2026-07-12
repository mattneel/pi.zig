# oh-my-pi Monorepo Census & Dependency Map

**Repo:** `/home/autark/src/zig/pi.zig/inspiration` (read-only vendored submodule of `can1357/oh-my-pi`, fork of Mario Zechner's `badlogic/pi-mono`)

**Pinned submodule commit:** `bb35e791890d33327ff184b1e94621d074b5bad4` — `2026-07-12 13:40:43 +0200` — `fix(ast): auto-wrap multi-node patterns instead of erroring`

All workspace versions are lockstep-pinned at **16.4.7** via the Bun `catalog:` mechanism in the root `package.json` (`inspiration/package.json`, `workspaces.catalog`). Workspaces are `packages/*` plus `python/robomp/web`.

---

## 1. Package census

LOC counted with `wc -l` over `.ts`/`.tsx` under each package (excluding `node_modules`, `dist`); "test" = `*.test.ts(x)`/`*.spec.ts` plus `test|tests|__tests__` directory files. Rust LOC counted over `src/*.rs` (inline `#[cfg(test)]` modules not separable, so Rust src figures slightly overstate).

### packages/ (TypeScript, Bun)

| Package | npm name | Purpose | src LOC | test LOC | Internal workspace deps |
|---|---|---|---:|---:|---|
| `agent` | `@oh-my-pi/pi-agent-core` | General-purpose agent runtime: the prompt→stream→tool-call→result loop, transport abstraction, state management, compaction, attachments, thinking levels, telemetry. Key files: `src/agent-loop.ts`, `src/agent.ts`, `src/compaction/`, `src/replay-policy.ts`. | 13,378 | 12,273 | pi-ai, pi-catalog, pi-natives, pi-utils, pi-wire, snapcompact |
| `ai` | `@oh-my-pi/pi-ai` | Unified multi-provider LLM client with streaming; ~50 provider clients (`src/providers/`: anthropic, openai-completions/responses/codex, google/vertex/gemini-cli, bedrock incl. hand-rolled SigV4 + eventstream, cursor, devin, gitlab-duo, kimi, ollama…), ~70 registry/auth entries (`src/registry/`), model-family "dialects" that normalize tool-calling/thinking syntax per family (`src/dialect/`: harmony, qwen3, kimi, glm, gemma, hermes, minimax, xml…), auth storage/broker/gateway, usage accounting. This is the layer ai.zig replaces. | 87,963 | 91,399 | pi-catalog, pi-utils, pi-wire |
| `catalog` | `@oh-my-pi/pi-catalog` | Model catalog: bundled model DB (`src/models.json`, 94,103 lines of data), provider discovery descriptors, model identity/classification/equivalence, thinking-capability metadata, model cache/manager. Contains ~84,653 lines of *generated* protobuf TS (`src/discovery/devin-gen/`, `src/discovery/cursor-gen/`) for the Cursor/Devin discovery endpoints; handwritten TS is ~16,000 LOC. | 100,693 (≈16k handwritten + ≈85k generated) + 94k JSON data | 10,650 | pi-utils (dev: pi-ai) |
| `coding-agent` | `@oh-my-pi/pi-coding-agent` | The product. CLI binary `omp` (`bin: {"omp": "src/cli.ts"}`), SDK (`src/sdk.ts`), all 32 tools (`src/tools/`, 45.6k LOC), session storage/tree/manager (`src/session/`, 29.5k — `agent-session.ts` alone is 16,503 lines), 4 front-end modes (`src/modes/`, 66.5k: interactive TUI, print, rpc, acp), web fetch/search stack (`src/web/`, 24.8k), extensibility (hooks/extensions/plugins, 16.2k), config/settings (14.3k incl. 5,264-line `settings-schema.ts`), subagent task system (11k), eval kernels (8.8k), edit engine (8.6k), MCP (8k), LSP (7.7k), DAP debug, commit splitting, hindsight memory, TTS/STT, collab, slash commands, internal URL schemes. Also 189 prompt `.md` files (5,161 lines) — prompts are file-based Handlebars templates, never inline strings (AGENTS.md rule). | 346,141 | 241,818 | hashline, omp-stats, pi-agent-core, pi-ai, pi-catalog, pi-mnemopi, pi-natives, pi-tui, pi-utils, pi-wire, snapcompact |
| `collab-web` | `@oh-my-pi/collab-web` | Browser guest client, mock host, and local relay for `/collab` live session sharing; React + marked. | 9,401 | 1,092 | pi-wire |
| `hashline` | `@oh-my-pi/hashline` | The line-anchored patch language and applier behind the `edit` tool: content-hash line anchors, stale-anchor recovery, streaming parse, pluggable FS backend (`src/apply.ts`, `parser.ts`, `recovery.ts`, `grammar.lark`, `prompt.md`). Self-contained — no workspace deps. | 5,838 | 2,898 | — (external: diff, lru-cache) |
| `mnemopi` | `@oh-my-pi/pi-mnemopi` | Local SQLite long-term memory engine ("Hindsight" backend): fact retention/recall/reflection, migrations, its own CLI and MCP server (`src/cli.ts`, `src/mcp-server.ts`). Embeddings via optional peer deps fastembed/onnxruntime-node. | 19,363 | 10,276 | pi-ai, pi-catalog, pi-utils |
| `natives` | `@oh-my-pi/pi-natives` | Thin JS/TS loader + binding contract around the Rust N-API `cdylib` (`native/index.js`, generated `index.d.ts`, embedded-addon extraction for compiled binaries). All heavy lifting is in `crates/`. | 2,749 | 1,536 | — (builds crates/pi-natives) |
| `snapcompact` | `@oh-my-pi/snapcompact` | Bitmap-frame context compression for vision-capable LLMs (renders context to images) + SQuAD eval suite in `research/`. | 2,030 | 1,192 | pi-ai, pi-natives, pi-utils, pi-wire |
| `stats` | `@oh-my-pi/omp-stats` | Local observability dashboard (`omp stats`): parses session logs into SQLite, aggregates usage/cost, serves an embedded React+chart.js web client. | 10,260 | 2,088 | pi-ai, pi-catalog, pi-utils |
| `swarm-extension` | `@oh-my-pi/swarm-extension` | Swarm orchestration extension for omp — packaged example of the extension API (peer-dep on `pi-coding-agent ^16`). | 1,179 | 68 | pi-utils (peer: pi-coding-agent) |
| `terminal-bench` | `@oh-my-pi/terminal-bench` | Runs harbor-framework/terminal-bench-2 against the local omp build with a live progress/spend/success dashboard (`src/runner.ts` + `agent/`). | 1,223 | 0 | — (drives the omp binary) |
| `tui` | `@oh-my-pi/pi-tui` | Terminal UI library with differential rendering: append-only renderer contract, editor component, keybindings, kitty keyboard/graphics, mouse, bracketed paste, autocomplete, markdown rendering (via marked), terminal capability detection. This is the layer ZigZag replaces. | 25,515 | 32,358 | pi-natives, pi-utils |
| `typescript-edit-benchmark` | `@oh-my-pi/typescript-edit-benchmark` | Edit-format benchmark suite using Babel-generated TypeScript source mutations; measures hashline vs other edit formats. | 6,701 | 582 | hashline, pi-agent-core, pi-coding-agent, pi-utils, pi-ai, pi-tui |
| `utils` | `@oh-my-pi/pi-utils` | Shared utilities: winston logger, streams/async helpers, dirs/env/paths, fetch-retry + TLS fetch, frontmatter, JSON helpers, mime, temp files, process manager & process tree (the only two files importing pi-natives: `src/ptree.ts`, `src/procmgr.ts`), snowflake IDs, worker host. | 19,702 | 5,231 | pi-natives |
| `wire` | `@oh-my-pi/pi-wire` | Shared collab live-session wire protocol types and relay constants; single `src/index.ts`. | 444 | 18 | — |

### crates/ (Rust)

| Crate | Purpose | src LOC |
|---|---|---:|
| `pi-natives` | Top-level N-API `cdylib` aggregating everything; JS-visible modules: shell, grep, glob, fd, workspace walker, fs_cache, ast, summary, highlight, text (ANSI-aware width/wrap), keys (kitty protocol), pty, ps (process-tree kill), clipboard, sixel, html→md, tokens (tiktoken BPE), appearance, power, prof, iso, snapcompact, task scheduling/cancellation. | 16,977 |
| `pi-shell` | Embedded bash runtime split out of pi-natives: wraps vendored `brush-core`/`brush-builtins`, persistent sessions, PTY, process mgmt, in-process coreutils dispatch, `which`, Windows support. | 37,720 |
| `pi-ast` | tree-sitter-based structural code summarizer + ast-grep pattern match/rewrite; 50+ grammars. | 3,401 |
| `pi-iso` | Task/worktree isolation backend resolver: APFS clonefile, btrfs/zfs reflink, overlayfs, Windows projfs/block-clone, rcopy fallback. | 4,052 |
| `pi-walker` | Parallel filesystem walker (ignore + globset) with cache + heartbeat, shared by grep/glob/fs-scan cache; plain Rust, no N-API deps. | 5,596 |
| `pi-uu-grep` | `grep` builtin re-implemented on grep-regex/grep-searcher, runs in-process in the shell. | 3,792 |
| `pi-uu-diff` | `diff` builtin backed by the `similar` crate. | 608 |
| `pi-uutils-ctx` | Thread-local stdio+cwd context so vendored uutils run as in-process shell builtins. | 406 |
| `crates/vendor/*` | Vendored: `brush-core` (26,292) + `brush-builtins` (9,228) — a bash reimplementation; `jaq` (1,442) — jq clone; 45 `uu-*` coreutils (cat, ls, find, sed, sort, tail, xargs, …). Total vendor: **98,311**. | 98,311 |

Docs map for the crates: `docs/native-crates.md` (crate roles table, quoted above at lines 14–24).

### python/

| Dir | Purpose | src LOC | test LOC |
|---|---|---:|---:|
| `python/omp-rpc` | Typed Python client for `omp --mode rpc` (NDJSON-over-stdio): typed commands, event listeners, host-tool helpers (`python/omp-rpc/pyproject.toml`). | 3,930 | 1,897 |
| `python/robomp` | Self-hosted GitHub triage/fix bot driving `omp --mode rpc` per-issue in git worktrees; FastAPI webhook + PAT sidecar + React web UI (`python/robomp/web` is a Bun workspace member). | 13,205 | 17,604 |

Neither is part of the agent — both are *external consumers* of RPC mode. **The Zig port does not need them**; they only matter as a compatibility test corpus for the RPC protocol (`docs/rpc.md`).

---

## 2. Internal dependency spine and forced port order

Workspace dependency edges (from each `package.json` `dependencies`):

```
wire        ← (none)
natives(TS) ← (none; wraps crates/pi-natives ← pi-shell, pi-ast, pi-iso, pi-walker,
               pi-uu-grep, pi-uu-diff, pi-uutils-ctx, vendor/brush-*, vendor/uu-*)
hashline    ← (none)
utils       ← natives                       (only ptree.ts, procmgr.ts)
catalog     ← utils
ai          ← catalog, utils, wire
tui         ← natives, utils
snapcompact ← ai, natives, utils, wire
mnemopi     ← ai, catalog, utils
stats       ← ai, catalog, utils
agent       ← ai, catalog, natives, utils, wire, snapcompact
coding-agent← agent, ai, catalog, tui, utils, natives, wire,
              hashline, mnemopi, snapcompact, stats(omp-stats)
collab-web  ← wire
swarm-extension        ← utils (peer: coding-agent)
typescript-edit-benchmark ← hashline, agent, coding-agent, ai, tui, utils
terminal-bench         ← (none; shells out to omp)
```

**Forced (topological) port order** — analogous to ai.zig's Vercel-SDK porting order:

1. **natives-equivalent layer** (Zig-native modules replacing the N-API surface: walker/glob/grep, text width/wrap, shell exec, ps, tokens, highlight — see §3 for what can be dropped)
2. **wire** (trivial, 444 lines of types — only if collab is in scope) and **hashline** (self-contained, port early; it is the edit tool's core and has its own test corpus)
3. **utils** (subset: dirs/env/paths, fetch-retry, frontmatter, JSON, logger)
4. **catalog** (models.json as embedded data + identity/effort/thinking helpers; skip the ~85k generated Cursor/Devin protobuf discovery)
5. **ai** → *replaced by ai.zig*; port work is the delta: catalog wiring, per-family dialects (`src/dialect/`), OAuth registry entries, auth storage
6. **tui** → *replaced by ZigZag*; port work is the component vocabulary (cards, editor, autocomplete, keybindings) on top of it
7. **snapcompact / mnemopi / stats** (optional; only agent-core's compaction hook touches snapcompact)
8. **agent** (agent-core loop — small, 13.4k LOC, well-specified)
9. **coding-agent** (the bulk; itself layered: tools → session → modes → extensibility)
10. peripheral: swarm-extension, benchmarks, collab-web

---

## 3. Classification for the Zig port

**Core — must port:**
- `coding-agent` (the product: tools, session, modes, config, prompts)
- `agent` (agent loop/state/compaction)
- `catalog` (handwritten ~16k + `models.json` data; drop generated `*-gen` protobuf discovery unless Cursor/Devin providers are wanted)
- `hashline` (edit tool core; self-contained)
- `utils` (a subset; much of it is Bun/Node-ecosystem shims Zig gets for free)
- `wire` (only if `/collab` is in scope)

**Replaced by a Zig dependency:**
- `ai` → **ai.zig** (providers, streaming, tool-loop). Remaining delta to port: dialect normalizers (`packages/ai/src/dialect/`), provider registry/auth/OAuth (`src/registry/`), usage accounting; behavioral specs in `docs/provider-streaming-internals.md`, `docs/provider-endpoint-constraints.md`, `docs/toolconv/*.md`.
- `tui` → **ZigZag** (vendored `zig-pkg/zigzag-0.1.2-…`). Behavioral specs: `docs/tui-core-renderer.md` (append-only contract), `docs/tui-runtime-internals.md`, `docs/tui.md`.
- `eval` tool's persistent Python kernel + Bun worker (`packages/coding-agent/src/eval/`, `docs/python-repl.md`, `docs/notebook-tool-runtime.md`) → **zig-quickjs-ng** (vendored `zig-pkg/quickjs_ng-0.0.0-…`) as the single scripting runtime; likewise extensions/hooks (currently TS modules, `docs/extensions.md`, `docs/hooks.md`) would target QuickJS.

**Rust crates — functionality, not code, to port.** They exist solely because Bun/TS cannot do this work in-process; the README brags "~55k lines of Rust… no fork/exec on the hot path" (README.md:371–403 module table). A Zig port writes these as ordinary Zig modules — no N-API, no loader (`docs/natives-architecture.md`, `docs/natives-binding-contract.md` become irrelevant plumbing):
- Needed in some form: walker/glob/grep (pi-walker + pi-uu-grep), text width/truncate/wrap (ANSI-aware — ZigZag likely covers part), fs_cache (mtime-keyed cache, `docs/fs-scan-cache-architecture.md`), keys (kitty protocol — ZigZag territory), pty, ps (process-tree kill), tokens (BPE counting), summary/ast (tree-sitter — link C tree-sitter from Zig), highlight, sixel/html/clipboard (nice-to-have media utils, `docs/natives-media-system-utils.md`).
- Decide-later: `pi-shell` + vendored `brush-*` + 45 `uu-*` coreutils + `jaq` (~135k LOC combined) exist to give Windows a native bash with in-process coreutils. A Zig port can initially shell out to system `bash`/`sh` and drop the entire vendored shell, sacrificing the "no WSL on Windows" story.
- `pi-iso` (CoW worktree isolation for subagent tasks): optional optimization; plain copy fallback (`rcopy`) is the semantic baseline.

**Peripheral / skippable:**
- `collab-web` (browser guest for `/collab`), `stats` (dashboard), `terminal-bench`, `typescript-edit-benchmark`, `swarm-extension` (sample extension), `snapcompact` (vision-based context compression experiment), `mnemopi` (optional memory backend; the memory *tool surface* retain/recall/reflect is setting-gated off by default per README.md:275), `python/` (both packages).

---

## 4. docs/ inventory (73 top-level .md — the behavioral spec set)

| Doc | One-line summary |
|---|---|
| `ERRATA-GPT5-HARMONY.md` | Historical research note on GPT-5 Harmony header leakage statistics (not a runtime contract). |
| `adding-a-provider.md` | How a provider is described in two halves (registry entry + API client) and the checklist to add one. |
| `advisor-watchdog.md` | The advisor second-model that reviews each turn and injects advice; WATCHDOG.md/yml config. |
| `ai-schema-normalize.md` | The unified tool-schema normalizer in pi-ai that all providers consume. |
| `approval-mode.md` | Tool approval mode: the two independent inputs gating destructive tools. |
| `arktype-guide.md` | Internal guide for migrating Zod→ArkType schemas (repo pinned to arktype 2.2.0). |
| `auth-broker-gateway.md` | Two cooperating HTTP services that hold OAuth refresh/access tokens on a broker host instead of laptops. |
| `bash-tool-runtime.md` | `bash` tool path: command normalization → execution → truncation/artifacts → rendering. |
| `blob-artifact-architecture.md` | How large/binary payloads live outside session JSONL; `artifact://` / `agent://` resolution. |
| `collab.md` | `/collab` live session sharing: relay, guest TUI rendering, read-write vs view links. |
| `compaction.md` | Compaction and branch summaries — keeping long sessions usable. |
| `config-usage.md` | Config discovery/resolution: scanned roots, precedence, consumers. |
| `context-files.md` | Auto-discovered Markdown context files (AGENTS.md etc.) injected into project context. |
| `custom-tools.md` | Authoring model-callable custom tools on the built-in tool pipeline. |
| `environment-variables.md` | Reference of every env var the runtime reads. |
| `extension-loading.md` | How `.ts`/`.js` extension modules are discovered and loaded at startup. |
| `extensions.md` | Primary extension-authoring guide (tool API, slash commands, hotkeys, TUI primitives). |
| `fs-scan-cache-architecture.md` | Contract for the shared Rust filesystem scan cache consumed by discovery/search. |
| `gemini-manifest-extensions.md` | Parsing Gemini-style `gemini-extension.json` manifests into capabilities. |
| `handoff-generation-pipeline.md` | `/handoff`: oneshot generation, session switch, context reinjection, persistence. |
| `hooks.md` | The hook subsystem (`src/extensibility/hooks/*`). |
| `install-id.md` | Persistent per-install UUID used as telemetry dedup key. |
| `keybindings.md` | Keybinding chords, remap file, `/hotkeys`. |
| `local-models.md` | Experiments with embedded local tiny-model paths. |
| `lsp-config.md` | Configuring language servers for the agent. |
| `macos-signing-notarization.md` | Release signing of macOS binaries. |
| `marketplace.md` | Plugin marketplace (Claude Code plugin registry format-compatible). |
| `mcp-config.md` | Adding/editing/validating MCP servers. |
| `mcp-protocol-transports.md` | MCP JSON-RPC message layer vs transport layer split. |
| `mcp-runtime-lifecycle.md` | MCP server discovery→connect→tools→refresh→teardown. |
| `mcp-server-tool-authoring.md` | How MCP server definitions become `mcp__*` tools; failure modes. |
| `memory.md` | Autonomous memory: extraction from past sessions, injected summaries. |
| `mnemosyne-memory-backend.md` | Using pi-mnemopi as the local long-term memory backend. |
| `models.md` | `models.yml`: model/provider config, overrides, credentials, runtime selection. |
| `native-crates.md` | Contributor map of `crates/` (quoted in §1). |
| `natives-addon-loader-runtime.md` | How `native/index.js` picks a `.node` file; embedded-payload extraction. |
| `natives-architecture.md` | Two-layer design of `@oh-my-pi/pi-natives`. |
| `natives-binding-contract.md` | JS/TS-side contract with the N-API addon. |
| `natives-build-release-debugging.md` | Build/release/debug runbook for the addon. |
| `natives-media-system-utils.md` | SIXEL, HTML→md, clipboard, tokens, appearance exports. |
| `natives-rust-task-cancellation.md` | Native work scheduling; `timeoutMs`/AbortSignal → Rust cancellation. |
| `natives-shell-pty-process.md` | shell/pty/ps/keys internals. |
| `natives-text-search-pipeline.md` | Text/search/code surface mapping JS↔Rust. |
| `non-compaction-retry-policy.md` | Standard API-error retry path in AgentSession. |
| `notebook-tool-runtime.md` | `.ipynb` handling and the kernel-backed Python runtime. |
| `plugin-manager-installer-plumbing.md` | `omp plugin` npm/git/link install plumbing → runtime capabilities. |
| `porting-from-pi-mono.md` | Checklist for merging upstream pi-mono changes. |
| `porting-to-natives.md` | Field notes for moving hot paths into Rust. |
| `provider-endpoint-constraints.md` | Per-provider endpoint quirks (providers are not interchangeable). |
| `provider-streaming-internals.md` | How token/tool streaming is normalized in pi-ai → agent-core → session events. **Key spec for ai.zig integration.** |
| `providers.md` | User-facing provider reference (40+ backends, roles, fallback chains). |
| `python-repl.md` | The eval tool's Python execution stack. **Spec for the QuickJS replacement decision.** |
| `resolve-tool-runtime.md` | Preview/apply pending-action workflow (`resolve` tool, `pushPendingAction`). |
| `rpc.md` | RPC mode: NDJSON protocol over stdio — full command/event reference. |
| `rulebook-matching-pipeline.md` | Rule discovery from 8 config formats → normalized `Rule` → precedence. |
| `sdk.md` | In-process SDK surface of pi-coding-agent. |
| `secrets.md` | Reversible secret obfuscation before text leaves the process. |
| `session-operations-export-share-fork-resume.md` | export/dump/share/fresh/fork/resume behavior. |
| `session-switching-and-recent-listing.md` | Recent-session discovery, `--resume` resolution, pickers. |
| `session-tree-plan.md` | Session tree architecture. |
| `session.md` | **Source of truth** for session representation, JSONL persistence, migration, reconstruction. |
| `settings.md` | Settings resolution: defaults → global → project → CLI overlay → runtime. |
| `skills.md` | File-backed skill packs: discovery and exposure to the model. |
| `slash-command-internals.md` | Slash command discovery, dedup, expansion at prompt time. |
| `system-prompt-customization.md` | System prompt assembly; SYSTEM.md / APPEND_SYSTEM.md. |
| `task-agent-discovery.md` | Subagent definition discovery/merge/resolution for the task tool. |
| `theme.md` | Theming: schema, loading, runtime, failure modes. |
| `tree.md` | `/tree` interactive session-tree navigator. |
| `ttsr-injection-lifecycle.md` | Time-Traveling Stream Rules: rule discovery → stream interrupt → retry injection. |
| `tui-core-renderer.md` | The append-only renderer contract (**ZigZag mapping spec**). |
| `tui-runtime-internals.md` | Terminal input → rendered output path in interactive mode. |
| `tui.md` | TUI contract for extensions/custom-tool UI. |
| `user-facing-packages.md` | Index of user-facing package CLIs needing root-docs coverage. |

**Subdirectories:** `docs/tools/` — 33 per-tool references (ask, ast-edit, ast-grep, bash, browser, checkpoint, debug, edit, eval, generate_image, github, glob, grep, inspect_image, irc, job, learn, lsp, manage_skill, memory_edit, read, recall, reflect, resolve, retain, rewind, search_tool_bm25, ssh, task, todo, tts, web_search, write). `docs/toolconv/` — 9 per-model-family tool-calling conventions (anthropic, deepseek, gemini, gemma, glm-4.5, harmony, kimi-k2, pi-native, qwen3) — the spec behind `ai/src/dialect/`. `docs/skills/` — authoring guides for extensions/hooks/marketplaces + examples.

---

## 5. Product surface (from README.md)

- **CLI name:** `omp`. Headline: "A coding agent with the IDE wired in" — "40+ providers · 32 built-in tools · 14 lsp ops · 28 dap ops · ~55k lines of Rust core" (README.md:25–27).
- **Four entry points** (README.md:405–469): interactive TUI (default), one-shot `omp -p`, `omp --mode rpc` / `--mode rpc-ui` (NDJSON over stdio), `omp acp` (Agent Client Protocol JSON-RPC for editors, e.g. Zed). Plus an in-process Node SDK (`ModelRegistry`, `SessionManager`, `createAgentSession`, `discoverAuthStorage`, README.md:417–441).
- **32 tools** in one namespace (README.md:220–275), some setting-gated off by default: `github`, `inspect_image`, `tts`, `checkpoint`, `rewind`, `search_tool_bm25`, `retain`, `recall`, `reflect`.
- **Model roles** `default`/`smol`/`slow`/`plan`/`commit`; `Ctrl+P` cycles role models; `/model` swaps mid-session; per-role fallback chains, path-scoped model sets, round-robin credentials (README.md:279–310).
- **Signature features:** hashline edits by content hash; eval kernels with tool re-entry; LSP-wired writes; DAP debugging; TTSR stream rules; typed subagents in isolated worktrees; advisor second model; `/collab` with client-sealed frames; web_search over 25 backends with site-aware extraction; internal URL schemes (`pr://`, `issue://`, `agent://`, `skill://`, `rule://`, `conflict://`, `artifact://`); conflict resolution via `@theirs/@ours/@base` writes; preview-then-`resolve` accept flow; Puppeteer browser tool; hindsight memory; native-inherit of `.claude`/`.cursor`/`.windsurf`/`.gemini`/`.codex`/`.cline`/`.github/copilot`/`.vscode` configs; self-generated shell completions for bash/zsh/fish.
- Platforms: macOS/Linux/Windows, Bun ≥ 1.3.14; MIT; © 2025 Mario Zechner, © 2025–2026 Can Bölük.

### Headline totals

| Layer | src LOC |
|---|---:|
| All TS packages (src, excl. tests) | ~653k (of which ~85k generated protobuf + 94k models.json data; handwritten ≈ 470k) |
| First-party Rust crates | ~72.5k |
| Vendored Rust (brush, uutils, jaq) | ~98.3k |
| Python (omp-rpc + robomp) | ~17.1k |

The port-critical handwritten core (agent + coding-agent + hashline + catalog-handwritten + utils-subset + wire) is roughly **400k LOC of TS**, of which coding-agent is 346k; ai (88k) and tui (25.5k) are replaced by ai.zig and ZigZag respectively.
