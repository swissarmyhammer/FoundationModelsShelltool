---
depends_on:
- 01KWYJ9XPG0K9VNSXCM66H3H2K
position_column: todo
position_ordinal: '8980'
title: ListProcesses + KillProcess ops
---
## What
Implement two `@Generable @Operation` structs in `Sources/ShellTool/Operations/`, using the `ShellContext` defined in the "ExecuteCommand op + ShellContext" task:

- `ListProcesses` (op `"list processes"`, no params): returns `ListProcessesResult`, an array of command-history rows (id, status, exitCode, lineCount, startedAt, duration, command) read from `ShellState.listCommands`.
- `KillProcess` (op `"kill process"`): `id` (required). SIGKILLs the process group by stored PID via `ShellRunner`'s group-kill helper; marks the `ShellState` record `killed`; returns `KillResult` (id, command, lines captured). Unknown or already-finished id → corrective message, not a thrown error.

This task owns the **concurrency test** (plan §7.3): `list processes` and `kill process` must respond correctly while a separate `execute command` is still running, since `ShellState` is an actor never held during a running command.

## Acceptance Criteria
- [ ] `list processes` dispatches through `AnyOperation` and returns the full history table
- [ ] `kill process` on a running command SIGKILLs its process group and flips the record to `killed`
- [ ] `kill process` on an unknown or already-finished id produces a corrective message
- [ ] `list processes` and `kill process` both succeed while a separate `execute command` is still in flight — the kill returns promptly, well under the running command's sleep duration
- [ ] `ListProcessesResult` and `KillResult` JSON shapes match the field names above

## Tests
- [ ] `Tests/ShellToolTests/ProcessOpsTests.swift`: `list processes` dispatch test with multiple recorded commands
- [ ] `kill process` success test (record flips to `killed`, lines-captured reported)
- [ ] `kill process` unknown-id corrective-message test
- [ ] Concurrent list/kill-while-running test: start a long `sleep` command without awaiting completion, call `list processes` (assert `running`), call `kill process` (assert prompt return, process tree gone)
- [ ] JSON-shape snapshot tests for `ListProcessesResult` and `KillResult`

## Workflow
- Use `/tdd` — the concurrency test is the anchor; write it first against a stub, then wire the real ops.