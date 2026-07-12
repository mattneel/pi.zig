# pi.zig

**Pi agent semantics. Zig runtime. One binary.**

pi.zig is an **independent, parity-focused Zig 0.16 implementation of the
Pi coding agent** (upstream: [oh-my-pi](https://github.com/can1357/oh-my-pi)'s
`omp`), built on `std.Io` with an all-Zig stack:

```
┌─────────────────────────────────────┐
│ pi.zig — Pi-compatible coding agent │
│ sessions · tools · compaction       │
│ steering · extensions · persistence │
├─────────────────────────────────────┤
│ ai.zig                              │
│ providers · streaming · tool loop   │
│ cancellation · structured output    │
├─────────────────────────────────────┤
│ ZigZag TUI                          │
│ input · transcript · dialogs        │
│ diffs · markdown · terminal I/O     │
└─────────────────────────────────────┘
```

plus [zig-quickjs-ng](https://github.com/mattneel/zig-quickjs-ng) as the
scripting runtime (extension host and the `eval` tool), replacing
upstream's Bun/Python runtimes.

> pi.zig is an independent project and is **not affiliated with or
> endorsed by** the oh-my-pi or pi-mono authors. The upstream agent is
> vendored read-only under `inspiration/` as the porting reference.

## Status

Early. The agent core is under active construction; nothing here is
usable as a daily driver yet.

| Surface | State |
| --- | --- |
| Foundations (deps wired, module skeleton, dependency smokes) | **done** |
| hashline edit engine (tags, lenient parser, apply, recovery, snapshots) | **done** — 222/222 upstream corpus cases ported |
| Agent core (loop, steering/follow-up queues, scheduler, mailboxes) | in progress (phase 1) |
| Essential tools: `read` · `bash` · `edit` · `write` | in progress (phase 1) |
| Print / JSON modes + JSONL session persistence | planned (phase 2) |
| Interactive TUI on ZigZag | planned (phase 3) |
| Compaction + session tree operations | planned (phase 4) |
| `glob` · `grep` · `todo`, approvals UI, slash commands | planned (phase 5) |
| QuickJS `eval` tool | planned (phase 6) |
| Extensions (QuickJS host) | planned (phase 7) |
| RPC mode | planned (phase 8) |

See [docs/roadmap.md](docs/roadmap.md) for per-phase acceptance criteria
and [docs/contracts.md](docs/contracts.md) for the behavioral guarantees
as they harden.

## What "parity" means here

Not "1:1". pi.zig targets upstream at these levels:

1. **Behavioral parity** — the agent loop, session format, steering
   boundaries, and tool semantics: upstream behavior specs are ported as
   Zig tests.
2. **Byte parity for model-facing strings** — tool output formats,
   truncation notices, hashline tags and error texts are reproduced
   exactly; models are steered by those bytes.
3. **Conceptual parity** — CLI shape and interactive UX follow upstream
   where the terminal stack allows.
4. **Intentional adaptations** — every deviation is itemized with
   rationale in the fidelity ledger
   ([docs/porting-guide.md §16](docs/porting-guide.md)).
5. **Deferred surfaces** — the status table above; notably the embedded
   shell (system `bash`/`sh` is used instead), OAuth flows, and the
   collab/memory/stats subsystems.

## Building

Requires **Zig 0.16.0**. If `zig` on your PATH is
[anyzig](https://github.com/marler8997/anyzig), the version is resolved
automatically from `build.zig.zon`.

```sh
zig build              # builds zig-out/bin/omp-zig
zig build test         # full test suite
zig build test -Dtest-filter=hashline   # filtered
zig build run -- --version
```

Dependencies are commit-pinned in `build.zig.zon`:
[ai.zig](https://github.com/mattneel/ai.zig) (providers, streaming,
tool-call plumbing, MCP), [ZigZag](https://github.com/meszmate/zigzag)
(terminal UI), and
[zig-quickjs-ng](https://github.com/mattneel/zig-quickjs-ng)
(quickjs-ng 0.15.1). Live-API smoke tests are opt-in (`-Dlive`) and
never run by default.

## Repository layout

- `src/` — the implementation (`core`, `session`, `tools`, `hashline`,
  `catalog`, `compact`, `js`, `modes`, `tui`, `testkit`, `prompts`)
- `inspiration/` — vendored upstream (read-only porting reference,
  pinned; see below)
- `docs/porting-guide.md` — the design doc: architecture, loop spec,
  type mapping, fidelity ledger. **Read before touching code.**
- `docs/roadmap.md` / `docs/contracts.md` — phases and guarantees
- `docs/research/` — nine deep research reports on upstream internals
  and the dependency surfaces, with file-level evidence
- `AGENTS.md` — ground rules for anyone (or anything) working here

## Upstream pin

`inspiration/` tracks oh-my-pi at v16.4.7 (`bb35e79`), a descendant of
Mario Zechner's [pi-mono](https://github.com/badlogic/pi-mono). It is
re-pinned deliberately, with a diff review of the agent loop and edit
engine first.

## License

Upstream oh-my-pi is MIT (© 2025 Mario Zechner, © 2025–2026 Can Bölük);
the vendored `inspiration/` tree retains that license, as do data and
prompt files copied verbatim into `src/` (e.g. `src/catalog/models.json`,
`src/prompts/`, the hashline grammar). A license for pi.zig's own code
has not been chosen yet.
