---
assignees:
- claude-code
depends_on:
- 01KY57RS5KNHPWKK23SQD0P6VT
position_column: todo
position_ordinal: '8280'
title: 'ExecuteCommand waitSeconds: soft-deadline detach and the `running` result shape'
---
## What

Expose the soft deadline on the `execute command` operation and teach the model the polling protocol through the result shape.

Files:
- `Sources/ShellTool/Operations/ExecuteCommand.swift`:
  - Add `waitSeconds: Int?` with `@Guide` text like: "Seconds to wait for completion before returning with the command still running (optional, default: 30; 0 returns immediately)". **No `@OperationParam` short flag** — pinned so this op and `get lines` cannot diverge. Distinct from `timeout` — `timeout` kills the child, `waitSeconds` only bounds this call.
  - Default: `nil` → 30 seconds (named constant, e.g. `defaultWaitSeconds`), so a runaway command can never stall a turn indefinitely; `0` → detach immediately. **Negative `waitSeconds` returns the corrective message `"waitSeconds must be non-negative"`** (same message and behavior pinned in the GetLines task).
  - Wire to `ShellRunner.run(request, wait:)`. On `.finished`, assemble today's `ExecuteResult` unchanged. On `.running`, assemble an `ExecuteResult` with `status: "running"`, the lines captured so far as the tail, `exitCode` omitted, and `outputNote` carrying the protocol: e.g. "still running — use get lines (with waitSeconds to wait for more output), kill process to stop, list processes to check status".
  - `ExecuteResult.exitCode` becomes `Int?` encoded with `encodeIfPresent` semantics (synthesized optional encoding — same technique as `ProcessRow.exitCode`): present for finished commands (`-1` sentinel for killed/timed-out unchanged), omitted while `running`. `durationMs` for a running result is elapsed-so-far.
- `Sources/ShellTool/ShellTool.swift` — extend `ShellTool.description` if needed so the fused tool advertises background execution.

Merge hygiene: the GetLines long-poll task runs in parallel and also edits `FusionTests.swift`/`CLIConvergenceTests.swift`. Add this task's schema/CLI assertions as **new, clearly-owned test functions** (e.g. `executeCommandWaitSecondsSchema...`) — never edit a shared test function both tasks touch.

## Acceptance Criteria
- [ ] Fast command (`echo hi`): result JSON byte-shape unchanged from today (status `completed`, `exitCode` present)
- [ ] Slow command with `waitSeconds: 1` (`sleep 30`): returns in ~1s with `status: "running"`, a valid `commandId`, `exitCode` absent from the JSON, and an `outputNote` naming `get lines` and `kill process`
- [ ] `waitSeconds: 0` returns immediately with `status: "running"`; negative `waitSeconds` returns the pinned corrective message
- [ ] Omitted `waitSeconds` uses the 30s default (assert via the named constant, not a 30s test sleep)
- [ ] `timeout` still enforced on a detached command (record later `timed_out`)
- [ ] Fused schema and CLI expose `waitSeconds` with no short flag

## Tests
- [ ] `Tests/ShellToolTests/ExecuteCommandTests.swift` — running-result shape (JSON keys present/absent), fast-path regression, waitSeconds 0/1/negative behavior, corrective paths untouched
- [ ] `Tests/ShellToolTests/FusionTests.swift` and `Tests/ShellToolTests/CLIConvergenceTests.swift` — new self-contained test functions for the `waitSeconds` surface
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running