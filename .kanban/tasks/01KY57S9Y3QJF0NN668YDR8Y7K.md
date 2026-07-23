---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky84543wqecb9nh4fhmcan5e
  text: |-
    Implemented via TDD (RED confirmed by compile failure referencing the not-yet-existing API, then GREEN).

    Changes:
    - Sources/ShellTool/Operations/ExecuteCommand.swift: added `waitSeconds: Int?` (no short flag, matching GetLines' pinned convention), `defaultWaitSeconds = 30` named constant, `waitDuration(for:)` pure helper (unit-testable without a real 30s sleep), negative-waitSeconds corrective check (same message as GetLines: "waitSeconds must be non-negative"), wired `execute(in:)` to `ShellRunner.run(request, wait:)` — `.finished` keeps the existing `result(for:in:)` path unchanged, `.running` goes through a new `runningResult(commandID:in:)` that reports `status: "running"`, the captured-so-far tail, `exitCode: nil`, and a fixed `runningOutputNote` naming `get lines`/`kill process`/`list processes`. `ExecuteResult.exitCode` changed `Int` -> `Int?` (encodeIfPresent via synthesized Encodable, same technique as `ProcessRow.exitCode`).
    - Did NOT change `ShellTool.description` — confirmed it's pinned byte-identical to the Rust `ShellExecuteTool::description` (doc comment + `makeCarriesTheSahDescription` test), so "advertise background execution" is carried instead by `waitSeconds`'s own `@Guide` text on the fused schema.
    - docs/USAGE.md: updated the `ExecuteCommand` doc-snippet to stay a byte-contiguous excerpt of the source (ReadmeSnippetTests enforces this).
    - DESIGN_NOTES.md: marked departure #12 ("ExecuteResult.exitCode is non-optional Int") as superseded by this task, kept the original text/pinned phrase for history (DesignNotesTests only pins phrase presence).
    - Tests added: Tests/ShellToolTests/ExecuteCommandTests.swift (default constant, pure waitDuration unit tests, fast-path JSON-shape regression, negative-waitSeconds corrective both direct-op and fused-tool paths, running-result JSON shape via real `sleep 30` + waitSeconds 1/0, timeout-still-fires-on-detached-command, ExecuteResult exitCode-omitted encoding test) plus new self-contained functions in FusionTests.swift (`executeCommandWaitSecondsSchemaWinsTheFusionCollisionOverGetLines`, `executeCommandWaitSecondsDispatchesThroughTheFusedToolAndReturnsARunningResult`) and CLIConvergenceTests.swift (`executeCommandWaitSecondsCLIFlagConvergesWithTheModelPathAndReturnsARunningResult`) — none of these touch a test function GetLines' parallel task already owns.

    swift test: 201/201 passing, run 3x for flake-check, all green. Adversarial double-check performed inline (Task subagent tool unavailable in this environment) — verdict PASS, one cosmetic note logged (test cleanup uses un-awaited `Task{}` inside `defer` to kill detached `sleep 30` children — harmless).

    Leaving in `doing` per /implement contract; ready for /review.
  timestamp: 2026-07-23T18:35:09.308717+00:00
depends_on:
- 01KY57RS5KNHPWKK23SQD0P6VT
position_column: done
position_ordinal: '9380'
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
- `Sources/ShellTool/ShellTool.swift` — extend `ShellTool.description` if needed so the fused tool advertises background execution. (Decision: left unchanged — it's pinned byte-identical to the Rust `ShellExecuteTool::description`, confirmed by `makeCarriesTheSahDescription`; `waitSeconds`'s own `@Guide` text carries the advertisement instead.)

Merge hygiene: the GetLines long-poll task runs in parallel and also edits `FusionTests.swift`/`CLIConvergenceTests.swift`. Add this task's schema/CLI assertions as **new, clearly-owned test functions** (e.g. `executeCommandWaitSecondsSchema...`) — never edit a shared test function both tasks touch.

## Acceptance Criteria
- [x] Fast command (`echo hi`): result JSON byte-shape unchanged from today (status `completed`, `exitCode` present)
- [x] Slow command with `waitSeconds: 1` (`sleep 30`): returns in ~1s with `status: "running"`, a valid `commandId`, `exitCode` absent from the JSON, and an `outputNote` naming `get lines` and `kill process`
- [x] `waitSeconds: 0` returns immediately with `status: "running"`; negative `waitSeconds` returns the pinned corrective message
- [x] Omitted `waitSeconds` uses the 30s default (assert via the named constant, not a 30s test sleep)
- [x] `timeout` still enforced on a detached command (record later `timed_out`)
- [x] Fused schema and CLI expose `waitSeconds` with no short flag

## Tests
- [x] `Tests/ShellToolTests/ExecuteCommandTests.swift` — running-result shape (JSON keys present/absent), fast-path regression, waitSeconds 0/1/negative behavior, corrective paths untouched
- [x] `Tests/ShellToolTests/FusionTests.swift` and `Tests/ShellToolTests/CLIConvergenceTests.swift` — new self-contained test functions for the `waitSeconds` surface
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running