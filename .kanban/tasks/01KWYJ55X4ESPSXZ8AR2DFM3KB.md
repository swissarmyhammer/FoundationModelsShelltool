---
depends_on:
- 01KWYJAWZQ8PN9031D9FCWG2N8
- 01KWYJ4QGVWPQ349JDZCWDYVAY
position_column: todo
position_ordinal: '8680'
title: 'Example: shell-demo (CLI / --chat / --script)'
---
## What
Complete the `shell-demo` executable (`Examples/ShellDemo/Sources/shell-demo/`) with its three modes:

- **Default — CLI**: task 6's grammar, over a real `.shell` store in the cwd.
- **`--chat`**: a `LanguageModelSession(tools: [shellTool], instructions: ...)`, gated on model availability (skip gracefully if unavailable — no hard failure in CI). Scripted prompts drive: run a command with long output → confirm the model sees the 32-line tail note → confirm it follows up with `grep history` / `get lines`; start a `sleep 60 &`-style long command → `list processes` → `kill process`; a deliberately denied command (`sudo rm -rf /`) → confirm a corrective message → confirm the model rephrases within the retry cap. Report op-call accuracy, rendered schema token size via `tokenCount(for:)`, and retry-cap behavior.
- **`--script`**: reads op lines from stdin, executes them sequentially in **one process** (so `execute` → `grep` → `get lines` chains share one session), doubling as the human-driven twin of the integration tests.

## Acceptance Criteria
- [ ] `swift run shell-demo` (default CLI mode) works end-to-end against a real `.shell` dir
- [ ] `swift run shell-demo --script` reads a sequence of ops from stdin and executes them against one shared session/context
- [ ] `swift run shell-demo --chat` is availability-gated: skips cleanly (non-zero exit avoided, informative message) when the on-device model is unavailable, and otherwise runs the scripted loop
- [ ] The chat harness's report includes op-call accuracy, schema token count, and observed retry-cap behavior on the denied-command scenario

## Tests
- [ ] `Tests/ShellToolTests/ExampleIntegrationTests.swift`: drive every op through `AnyOperation` end-to-end using the example's `ShellContext` construction path
- [ ] `--script` mode test: pipe a fixed sequence of op lines through stdin, assert final state (e.g. a `get lines` after an `execute` returns the expected content) — this is the one-process-shared-session contract from plan §3
- [ ] CLI integration test invoking the built executable as a subprocess for at least one full flow (execute → grep → get lines)
- [ ] `--chat` mode is explicitly excluded from the automated suite (live-model, manual-run per plan §7.4) — document this exclusion in the test file rather than silently omitting it

## Workflow
- Use `/tdd` for `--script` mode and the integration tests; the `--chat` harness is written directly (it's manual-run, not test-driven) but must not break `swift build`.