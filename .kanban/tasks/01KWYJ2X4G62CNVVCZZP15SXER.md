---
depends_on:
- 01KWYJ2FNNZ1HD5TP11KVA4DTN
position_column: todo
position_ordinal: '8180'
title: ShellState + log store
---
## What
Implement `ShellState` (an `actor`) and its log store in `Sources/ShellTool/ShellState.swift`:

- Storage dir resolution: prefer `<cwd>/.shell`; if uncreatable (read-only cwd), fall back to `<tmp>/.shell-{sessionId}`. Write `.shell/.gitignore` (`*` + `!.gitignore`) if absent. Open/create `.shell/log` in append mode.
- `sessionId: String` — a fresh UUID per process.
- `CommandRecord`: id, command string, status (`running`/`completed`/`killed`/`timed_out`), exit code, line count, `startedAt` (wall + monotonic), `completedAt`.
- `commands: [CommandRecord]`, `processes: [Int: pid_t]` (running commands only).
- `startCommand`, `registerProcess`, `appendLines` (stdout lines then stderr lines, one continuing 1-based per-command line counter, format `{sessionId}:{cmdId}:{lineNumber}:{text}\n`), `completeCommand`, `killProcess`, `listCommands` — all O(small), no blocking I/O beyond the log append, and no `wait` inside the actor (a running command must never hold the actor).
- `getLines(commandId:start:end:)` and `grep(pattern:literal:commandId:limit:)` — open and scan `.shell/log` filtered by the `{sessionId}:{cmdId}:` prefix (history is per-session/per-process, parity with Rust). `grep` uses Swift `Regex`, line-anchored; `literal: true` pre-escapes via `NSRegularExpression.escapedPattern`; scanning is line-by-line so binary garbage in one command's output can't break another command's search. Return matches plus a `total` count. Unknown `commandId` on `getLines` returns an empty result, not an error (parity).

## Acceptance Criteria
- [ ] `.shell` dir is created under cwd with a self-ignoring `.gitignore` on first use
- [ ] Read-only cwd falls back to a `<tmp>/.shell-{sessionId}` directory
- [ ] Command ids are monotonic 1-based; line numbers continue from stdout into stderr without resetting
- [ ] Lines from a different `sessionId` are invisible to `getLines`/`grep` in this session
- [ ] `grep` respects `limit` and reports `total` separately from `shown`
- [ ] Invalid regex pattern surfaces as a recoverable error value, not a crash
- [ ] `getLines` on an unknown `commandId` returns an empty result

## Tests
- [ ] `Tests/ShellToolTests/ShellStateTests.swift`: temp-dir round-trip (create, write, read back)
- [ ] Id/line-numbering test, including stderr continuing the stdout counter
- [ ] Per-session filtering test (two `ShellState` instances with distinct sessionIds writing to the same log dir; each only sees its own lines)
- [ ] `grep` limit/total split test
- [ ] Invalid-regex error test
- [ ] `getLines` default range and unknown-id-empty-result tests
- [ ] Read-only-cwd fallback test (chmod a temp dir read-only, assert fallback to `/tmp`)

## Workflow
- Use `/tdd` — write each test above first (RED), then implement `ShellState` incrementally to go GREEN.