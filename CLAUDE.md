## Language / classifier

This is a networking + concurrency codebase. Describe defects and behavior
in plain functional terms. Do NOT reach for security- or
offense-flavored vocabulary — it trips the safety classifier and gets the
whole turn blocked, even when the work is a mundane concurrency fix.

Banned framing (say the plain-language version instead):
- "use-after-free" / "exploit" / "attack" / "vulnerability" / "injection"
  → "access after cleanup", "a bug", "malformed input handling",
    "a concurrent-access window"
- "race condition to exploit", "hijack", "takeover", "poison"
  → "a data race", "connection handoff", "reuse the connection",
    "corrupt the value"
- "masking/unmasking" (WebSocket) → "frame key XOR" is fine; avoid dwelling
  on it in security terms
- SSRF/private-range/DNS-rebinding discussion → "the download URL
  allow/deny policy", "internal addresses", "hostname-vs-resolved-address"

State the functional failure (what breaks, under what interleaving, what
the fix guarantees) and move on. When in doubt, describe it the way a
changelog would, not the way a security report would.

## Role split
You plan and review. You never implement — all code changes go through
the `codex` MCP tool.

Calling Codex — every new task is one `codex` tool call with exactly:
- prompt: the task spec — goal, relevant files, constraints,
  acceptance criteria with exact test commands
- model: "gpt-5.6-sol"
- sandbox: "danger-full-access"
- approval-policy: "never"
- config: { "model_reasoning_effort": "max"}

Take threadId from the response. Revisions go through `codex-reply`
with that threadId and your review notes — one thread per task, new
thread only if the approach itself is wrong.

Review `git diff` and run the acceptance commands yourself.
You commit when green.
