---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky827x7ae06khbfmy07testz
  text: |-
    Implementation complete, TDD followed throughout.

    RED: added new tests to ShellRunnerTests.swift (deadline-detach, background finalize, detached timeout, cancellation-detach) and ProcessOpsTests.swift (kill of a detached command) referencing `run(_:wait:)`, `.running`/`.timedOut`/`.killed` cases that didn't exist yet — confirmed compile failure (`swift build --build-tests` failed with "cannot infer contextual base") before writing any implementation.

    GREEN: implemented the split in Sources/ShellTool/ShellRunner.swift:
    - `run(_ request:)` is now a thin convenience over `run(_:wait: nil)`, unwrapping `.finished` — kept so every existing call site (ExecuteCommand.swift, all pre-existing tests) compiles and behaves identically; no signature churn needed downstream.
    - `run(_ request:, wait: Duration?) -> RunResult` (`.finished(Outcome)` / `.running(Int)`) spawns the child's full supervision (`runBody`, a static func with all of yesterday's `Subprocess.run`/§9-teardown/`completeIfRunning` logic) as an unstructured `Task`, tracked in a new `RunSupervisor` (Sources/ShellTool/RunSupervisor.swift, mirrors ProcessRegistry's lock-based design).
    - `wait == nil` awaits `bodyTask.value` inside `withTaskCancellationHandler`, killing the pid on cancellation — today's exact pre-detach contract, unchanged.
    - Finite `wait` races `bodyTask` against `Task.sleep(for: wait)` via `raceDeadline`, which feeds both racers' results into a single-value `AsyncStream` rather than a task group — deliberately, since a task group's scope can't exit while a losing child is still suspended on `bodyTask.value`, which would block the "prompt .running return" requirement. Ambient cancellation of the wait is folded into the same race (`onCancel` yields `.deadline`), so cancelling the awaiting task now detaches instead of killing.
    - `timeout` needed no changes — it already lives inside `runBody`'s inner task group, so it keeps ticking across detach for free.

    Compile hiccup: `Mutex<pid_t>` is `~Copyable` under Swift 6.2's strict-concurrency mode, so passing it as a plain function parameter to the extracted `runBody` required an explicit `borrowing` ownership annotation — fixed, builds clean.

    GREEN verified: `swift test` → 187/187 pass, 0 failures, 0 warnings on a clean rebuild (`rm -rf` of build intermediates + `swift build --build-tests` also 0 warnings/errors). `mcp__sah__diagnostics check working` also reports 0/0.

    really-done: hard verification command (`swift test`) run fresh and green. The advisory adversarial double-check step could not run through the normal `double-check` subagent — no `Task`-spawning tool is available in this nested-agent context (only `TaskStop`/`EnterWorktree`/`SendMessage` surfaced). Substituted a manual adversarial self-review of the full diff (race-condition analysis of `raceDeadline`'s AsyncStream-based race, double-yield safety, borrowing-parameter correctness, dead-code check on `RunSupervisor.trackedCommandIDs`) — no issues found. Logging this substitution per really-done's contract rather than silently skipping the gate.

    Left in `doing` per /implement's contract — not moving to `review`.
  timestamp: 2026-07-23T18:01:43.402646+00:00
depends_on:
- 01KY57R5GC12AQJ439NS9RENTY
- 01KY5QYMNJ4YKC6MANB14ZW0TF
position_column: doing
position_ordinal: '80'
title: 'Detached execution: ShellRunner soft-deadline wait + supervisor with process-exit sweep'
---
## What

Restructure `ShellRunner` so a run can outlive the tool call that started it, with a soft-deadline wait — the mechanism behind `execute command`'s `waitSeconds`. The pid registry + exit sweep already landed in the precursor task; this task's detached path just keeps using its register/deregister hooks.

Files:
- `Sources/ShellTool/ShellRunner.swift` — split `run(_:)` into: (1) start the `Subprocess.run` supervision body in an **unstructured `Task`** whose handle is tracked by a supervisor, and (2) an await-with-deadline: `run(request, wait: Duration?)` returns either `.finished(Outcome)` (child exited within the wait) or `.running(commandID)` (deadline elapsed; the detached task continues draining, appending lines incrementally, enforcing `timeout`, and finalizing via `completeIfRunning` when the child exits). `wait == nil` waits to completion (today's behavior). Keep §9 semantics on the detached path too: stream EOF → unconditional group-kill, so a daemonizing child that closes its pipes still cannot leak.
- Supervisor for the `Task` handles: extend `Sources/ShellTool/ShellState.swift` (which already tracks `processes: [Int: pid_t]`) or a small type owned by `ShellContext` (`Sources/ShellTool/ShellContext.swift`).
- Cancellation semantics change: cancelling the *awaiting* tool-call task during the wait window detaches the child (the unstructured task and supervisor own it) rather than killing it — the group-kill guarantee is carried by explicit `kill process`, stream EOF, `timeout`, and the precursor's exit sweep. Update the `withTaskCancellationHandler`/`onCancel` handling and doc comments accordingly.

`timeout` keeps its meaning — kill the child after N seconds total, ticking across detach (the timer already lives inside the body task group, so it keeps running for free). Two distinct clocks: `timeout` bounds the *child*, `wait` bounds the *tool call*.

Implementation note (landed): `run(_:)` (single-arg) is kept as a thin convenience wrapping `run(_:wait: nil)` and unwrapping `.finished` — this is what keeps every existing call site (`ExecuteCommand.swift`, all pre-existing tests) compiling and behaving identically without any signature churn downstream. The supervisor landed as a new small type, `RunSupervisor` (`Sources/ShellTool/RunSupervisor.swift`), owned by `ShellRunner` (mirrors `ProcessRegistry`'s lock-based design) rather than extending `ShellState`/`ShellContext`.

## Acceptance Criteria
- [x] `run(request, wait: .seconds(1))` on `sleep 30` returns `.running(commandID)` in ~1s; `list processes` shows the record `running`
- [x] The detached child finalizes in the background: after it exits, the record flips to `completed` with the real exit code and all output lines recorded
- [x] `timeout` fires on a detached command: record ends `timed_out`, exit code `-1`, group killed
- [x] `kill process` against a detached command kills the group, flips the record to `killed`, and the supervisor task ends
- [x] Cancelling the awaiting task mid-wait leaves the child running and supervised (record still `running`, child alive, later finalized)
- [x] Registry hooks from the precursor still register on spawn / deregister on finalize along the detached path

## Tests
- [x] `Tests/ShellToolTests/ShellRunnerTests.swift` — deadline detach returns `.running` promptly; background finalize (poll `listCommands` until `completed`); detached timeout; cancellation-detach
- [x] `Tests/ShellToolTests/ProcessOpsTests.swift` — kill of a detached command
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running