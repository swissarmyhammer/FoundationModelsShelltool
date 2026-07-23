---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky8hbzznqvd01y4w57z873jr
  text: 'Dependency refresh done: `swift package update FoundationModelsOperationTool` resolved to a1dcdbc6e48395a7eb7b7a72bfd9590974c8d4e2 (matches expected). Verified EventEmittingContext.swift, EventEmittingTool.swift, ForkableContext.swift, ForkableTool.swift exist in the checkout with connecting(_:)/forked(), and old connect(/OperationEventSinkHolder are gone. Read OperationTool.swift''s conditional EventEmittingTool conformance and unconditional ForkableTool conformance, plus the upstream EventEmittingToolTests.swift/ForkableToolTests.swift fixtures for the exact usage pattern. Proceeding to explore ShellTool sources and write failing tests.'
  timestamp: 2026-07-23T22:26:05.941653+00:00
- actor: claude-code
  id: 01ky8kg04hy66f2938bny99mg6
  text: |-
    Implementation complete, all green.

    **Changes:**
    - `Sources/ShellTool/ShellContext.swift` — conforms to `EventEmittingContext`: `public let operationEventSink: (any OperationEventSink)?` (default `nil`) plus `public func connecting(_:) -> ShellContext` sharing `state`/`runner`/`policy`. File header documents the v1 fork stance (no `ForkableContext` conformance — one shared machine).
    - `Sources/ShellTool/ShellRunner.swift` — added `DetachedEventRoute` (sink/tool/op), `progressInterval` (injectable, default `defaultProgressInterval = .seconds(5)`), and `run(_:wait:events:)`. On the `.deadline` branch (the moment a command actually detaches) it fires a background `runDetachedEventLoop` that posts throttled `.progress` (task-group merge pattern, mirroring `waitForCompletion`'s style) and exactly one `.completed` once `bodyTask` settles, reading the authoritative `ShellState` record (not the runner's own `Outcome`) so a concurrent `kill process` is reported as `killed` correctly.
    - `Sources/ShellTool/ShellState.swift` — added `record(commandID:) -> CommandRecord?` and `CommandRecord.durationMs`, deduping the by-id lookup and ms-conversion previously inlined twice in `ExecuteCommand` (now three call sites: `ExecuteCommand.result`, `.runningResult`, `ShellRunner.postCompletedEvent`).
    - `Sources/ShellTool/Operations/ExecuteCommand.swift` — captures `context.operationEventSink` once at the very top of `execute(in:)` (capture-at-start rule), builds a `DetachedEventRoute` (tool: `ShellTool.name`, op: `Self.opString`) only when a sink is connected, passes it to `runner.run(request, wait:, events:)`.
    - `Sources/ShellTool/ShellTool.swift` — doc-only: explains `EventEmittingTool`/`ForkableTool` conformance comes from the upstream `OperationTool` machinery (conditional on `ShellContext: EventEmittingContext`, unconditional `ForkableTool`), verified by tests rather than hand-rolled.
    - Tests: new `Tests/ShellToolTests/ShellEventsTests.swift` (9 tests: casts from `any Tool`, `connecting` shared-history + independent routing, `forked` shared history, `.completed` exactly once for completed/killed/timed_out, no-events-within-wait-window, capture-at-start survives discarding the starting copy) + 2 new tests in `ShellRunnerTests.swift` (`defaultProgressIntervalIsFiveSeconds`, `progressEventsAreThrottledToTheInjectedInterval` using an injected 100ms interval, not real 5s).

    **TDD note:** added the minimal protocol-conformance scaffolding first (compile-enabling, low-risk boilerplate), then wrote the full `ShellEventsTests` suite, then did a genuine RED/GREEN cycle on the actual posting *logic*: temporarily short-circuited the `postDetachedEvents` call site (`if false, let events`), ran the new tests and watched 6/9 fail for the right reason (no events posted), then restored the real call and watched all 9 pass. `swift test --filter ShellRunnerTests`/`ShellEventsTests` runs shown in the session.

    **Final `swift test`: 212 tests, 18 suites, all passed, zero failures, zero warnings** (confirmed twice, including a touch-triggered rebuild to rule out stale-cache silence).

    **Review finding (justification, not fixed):** `mcp__sah__review review working` flagged pre-existing duplication between `ExecuteCommand.result(for:in:)` and `.runningResult(commandID:in:)` (both fetch `stored`/`output` identically). Confirmed via diff this duplication predates this task — I only touched the `record =` and `durationMs:` lines inside each. Left as-is per "no unrelated refactors while implementing"; worth a follow-up cleanup task if desired.

    Dependency refresh (a1dcdbc6e48395a7eb7b7a72bfd9590974c8d4e2) and research notes are in the earlier comment on this task.

    Leaving in `doing` for `/review` per the implement workflow.
  timestamp: 2026-07-23T23:03:14.321599+00:00
depends_on:
- 01KY57RS5KNHPWKK23SQD0P6VT
position_column: doing
position_ordinal: '80'
title: 'ShellTool: post completion and throttled progress events from detached commands'
---
## What

Make the fused `shell` tool an `EventEmittingTool`: a detached command's supervisor posts out-of-band events so a session host can learn about completion without the model polling. This package depends only on `FoundationModelsOperationTool` — never on the Router.

**Cross-repo prerequisite (prose, not a board dependency):** requires the OperationTool **pure tool-capabilities** rework (`EventEmittingTool.connecting(_:) -> any Tool` + `ForkableTool.forked()` with blanket copy default, replacing the removed `connect(_:)` mutation and `OperationEventSinkHolder` — task `f7jjm6x` on the board in `/Users/wballard/github/swissarmyhammer/FoundationModelsOperationTool`, `long-running` tag) to have landed and this package's dependency to resolve a version containing it. Verify before starting; if absent, stop and report rather than hand-rolling substitute protocols.

**Subscription contract (pinned):** the embedder never wires events by hand. A host that knows `EventEmittingTool` (e.g. Router) maps its `[any Tool]` list through `connecting(sessionSink)` during session setup and hands the *instanced copies* to the model; a plain `LanguageModelSession` embedder may call `shell.connecting(mySink)` directly. Instances returned by `connecting` share the underlying `ShellState`/supervisor (one command history, one `.shell` store) — only the event route differs per copy.

**Fork stance (pinned for v1):** the shell relies on the **blanket `forked()` default** (a struct copy sharing the engine by reference) — `ShellContext` does NOT implement `ForkableContext` in v1. One shared machine: parent and fork share command history; each session's events route through its own `connecting` copy. Branched history is a possible later tool-internal upgrade; do not build it here.

Files:
- `Sources/ShellTool/ShellContext.swift` — conform to the OperationTool `EventEmittingContext` value surface: `let operationEventSink: (any OperationEventSink)?` (default `nil` = no events, zero behavior change) plus the `connecting(_:) -> Self` copy that replaces the sink while sharing `state`/`runner`/`policy`.
- `Sources/ShellTool/ShellRunner.swift` (detached path) — **capture the context's sink once, at operation start**, into the detached supervisor (the capture-at-start rule: ownership stays with the session whose turn started the command, regardless of later re-instancing or forks). Post events with `tool: "shell"`, `op: "execute command"`, `correlationID: commandID`:
  - `.completed` — exactly once, when a *detached* command finalizes (any of `completed`/`timed_out`/`killed`), carrying command string, final status, exit code, line count, duration ms. A command that finishes within the wait window posts nothing — its result was already delivered in-band.
  - `.progress` — throttled at the source to at most one per `progressInterval` (named constant, propose 5s; injectable for tests), carrying line count so far, only while detached.
- `Sources/ShellTool/ShellTool.swift` — verify the tool `make(...)` returns is discoverable as `any EventEmittingTool` AND `any ForkableTool` via cast from `any Tool`, that `connecting` yields a working sink-bound copy, and that the blanket `forked()` copy shares the engine (conformances come from the OperationTool machinery; verify and document rather than hand-roll).

## Acceptance Criteria
- [x] The value returned by `ShellTool.make()` casts to both `any EventEmittingTool` and `any ForkableTool` from an `any Tool` existential; `connecting(fakeSink)` returns a usable tool copy — verified by tests performing exactly those casts, no ShellTool-specific knowledge
- [x] Two `connecting` copies over one `make()` result share command history (a command run via copy A is visible via `list processes` through copy B) while posting events to their own sinks only; a `forked()` copy likewise shares history (one shared machine)
- [x] With a sink-bound copy: a detached command posts `.completed` exactly once with correct status/exitCode/lineCount; a killed and a timed-out detached command each post `.completed` with their status
- [x] A command finishing within the wait window posts no events; the un-instanced original posts nothing anywhere
- [x] `.progress` events respect the throttle interval (assert via injected interval, not wall-clock 5s waits)
- [x] Sink captured at operation start: re-instancing (or discarding) the copy after a command detaches does not change where that command's events go
- [x] Public API documented per the doc-coverage gate, including the v1 fork stance

## Tests
- [x] `Tests/ShellToolTests/ShellRunnerTests.swift` (or new `ShellEventsTests.swift`) — cast-and-connecting/forked from `any Tool`; shared-state/independent-route tests; fake sink actor records events; all criteria above
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running