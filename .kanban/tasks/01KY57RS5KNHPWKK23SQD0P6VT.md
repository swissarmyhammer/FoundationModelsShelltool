---
assignees:
- claude-code
depends_on:
- 01KY57R5GC12AQJ439NS9RENTY
- 01KY5QYMNJ4YKC6MANB14ZW0TF
position_column: todo
position_ordinal: '8180'
title: 'Detached execution: ShellRunner soft-deadline wait + supervisor with process-exit sweep'
---
## What

Restructure `ShellRunner` so a run can outlive the tool call that started it, with a soft-deadline wait — the mechanism behind `execute command`'s `waitSeconds`. The pid registry + exit sweep already landed in the precursor task; this task's detached path just keeps using its register/deregister hooks.

Files:
- `Sources/ShellTool/ShellRunner.swift` — split `run(_:)` into: (1) start the `Subprocess.run` supervision body in an **unstructured `Task`** whose handle is tracked by a supervisor, and (2) an await-with-deadline: `run(request, wait: Duration?)` returns either `.finished(Outcome)` (child exited within the wait) or `.running(commandID)` (deadline elapsed; the detached task continues draining, appending lines incrementally, enforcing `timeout`, and finalizing via `completeIfRunning` when the child exits). `wait == nil` waits to completion (today's behavior). Keep §9 semantics on the detached path too: stream EOF → unconditional group-kill, so a daemonizing child that closes its pipes still cannot leak.
- Supervisor for the `Task` handles: extend `Sources/ShellTool/ShellState.swift` (which already tracks `processes: [Int: pid_t]`) or a small type owned by `ShellContext` (`Sources/ShellTool/ShellContext.swift`).
- Cancellation semantics change: cancelling the *awaiting* tool-call task during the wait window detaches the child (the unstructured task and supervisor own it) rather than killing it — the group-kill guarantee is carried by explicit `kill process`, stream EOF, `timeout`, and the precursor's exit sweep. Update the `withTaskCancellationHandler`/`onCancel` handling and doc comments accordingly.

`timeout` keeps its meaning — kill the child after N seconds total, ticking across detach (the timer already lives inside the body task group, so it keeps running for free). Two distinct clocks: `timeout` bounds the *child*, `wait` bounds the *tool call*.

## Acceptance Criteria
- [ ] `run(request, wait: .seconds(1))` on `sleep 30` returns `.running(commandID)` in ~1s; `list processes` shows the record `running`
- [ ] The detached child finalizes in the background: after it exits, the record flips to `completed` with the real exit code and all output lines recorded
- [ ] `timeout` fires on a detached command: record ends `timed_out`, exit code `-1`, group killed
- [ ] `kill process` against a detached command kills the group, flips the record to `killed`, and the supervisor task ends
- [ ] Cancelling the awaiting task mid-wait leaves the child running and supervised (record still `running`, child alive, later finalized)
- [ ] Registry hooks from the precursor still register on spawn / deregister on finalize along the detached path

## Tests
- [ ] `Tests/ShellToolTests/ShellRunnerTests.swift` — deadline detach returns `.running` promptly; background finalize (poll `listCommands` until `completed`); detached timeout; cancellation-detach
- [ ] `Tests/ShellToolTests/ProcessOpsTests.swift` — kill of a detached command
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running