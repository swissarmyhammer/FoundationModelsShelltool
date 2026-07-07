---
depends_on:
- 01KWYJ2X4G62CNVVCZZP15SXER
- 01KWYJ3DKZTTR3VYT7MFZTQ0G3
- 01KWYJ3TNK43WPMM9T8E7RQJ37
position_column: todo
position_ordinal: '8480'
title: Five operations + ShellTool.make()
---
## What
Implement the five `@Generable @Operation` structs and fuse them into the `shell` tool, in `Sources/ShellTool/Operations/` (one file per op) and `Sources/ShellTool/ShellTool.swift`:

- `ExecuteCommand` (op `"execute command"`): `command` (required), `timeout?` secs, `workingDirectory?`, `environment?` (JSON-string map, parsed/validated as in Rust — `@Generable` has no dictionary type). Pipeline: `ShellPolicy` validation → `ShellRunner.run` → `ShellState` storage under a fresh `command_id` → `ExecuteResult` (commandId, status, exitCode, lines, durationMs, `output: [String]` as `"{lineNumber}: {text}"` for the **last 32 lines**, `outputNote?` for the "showing last 32 of N — use get lines" / truncation / binary note).
- `ListProcesses` (op `"list processes"`, no params): returns `ListProcessesResult`, an array of command-history rows (id, status, exitCode, lineCount, startedAt, duration, command).
- `KillProcess` (op `"kill process"`): `id` (required). SIGKILLs the process group by stored PID via `ShellRunner`'s group-kill helper (task 3); marks the record `killed`; returns `KillResult` (id, command, lines captured). Unknown/already-finished id → corrective message.
- `GrepHistory` (op `"grep history"`): `pattern` (required), `literal?` (default false), `commandId?`, `limit?` (default 10, and documented as 10 — plan §8.3 departure from Rust's stale "50" doc string). Returns `GrepMatches` (matches + `shown`/`total`). Invalid regex → corrective message.
- `GetLines` (op `"get lines"`): `commandId` (required), `start?` (default 1), `end?` (default last line). Returns `LineRange` (commandId, first, last, numbered lines). Unknown id → empty result (parity, not an error).

All five share a `ShellContext` (the `ShellState` actor + `ShellRunner` + `ShellPolicy`). Fuse via `OperationTool` with tool name `"shell"` and description *"Virtual shell with history and process management. Execute commands, grep output history, and manage running processes."* Wire the missing-`op` → `execute command` default via the resolver's opt-in `inferOp` closure (`OperationResolver.InferenceHook`). Field names are camelCase (`workingDirectory`, `commandId`); rely on the upstream resolver's snake_case normalization for `working_directory`/`command_id` payload parity — do not hand-roll normalization.

`ShellTool.make(context:)` returns the fused `OperationTool<ShellContext>`.

## Acceptance Criteria
- [ ] All five ops dispatch correctly through `AnyOperation` by their exact sah op strings
- [ ] A payload with no `op` field defaults to `execute command`
- [ ] snake_case payload keys (`working_directory`, `command_id`) resolve to the same result as camelCase
- [ ] Missing required params (`command`, `id`, `pattern`, `commandId`) produce corrective messages, not thrown errors
- [ ] A denied command (per `ShellPolicy`) produces a corrective message
- [ ] `KillProcess` on an unknown id produces a corrective message
- [ ] `ExecuteResult.output`/`outputNote` shows the 32-line tail note only when total lines > 32
- [ ] `list processes` and `kill process` succeed while a separate `execute command` is still running (concurrency — plan §7.3)
- [ ] Each output struct's JSON shape matches the field names specified above

## Tests
- [ ] `Tests/ShellToolTests/DispatchTests.swift`: one dispatch test per op through `AnyOperation`
- [ ] snake_case/camelCase payload parity test for at least `execute command` and `get lines`
- [ ] Corrective-message tests: missing required param (per op), unknown kill id, denied command
- [ ] Tail-note-appears-only-past-32-lines test
- [ ] Concurrent list/kill-while-running test: start a long `sleep` command without awaiting completion, call `list processes` (assert `running`), call `kill process` (assert it returns promptly, well under the sleep duration)
- [ ] JSON-shape snapshot tests for `ExecuteResult`, `ListProcessesResult`, `KillResult`, `GrepMatches`, `LineRange`

## Workflow
- Use `/tdd` — the dispatch tests and corrective-message tests are the RED-first anchors per op.