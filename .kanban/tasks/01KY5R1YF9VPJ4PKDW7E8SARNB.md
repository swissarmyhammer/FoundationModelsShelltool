---
assignees:
- claude-code
depends_on:
- 01KY57RS5KNHPWKK23SQD0P6VT
position_column: todo
position_ordinal: '8780'
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
- [ ] The value returned by `ShellTool.make()` casts to both `any EventEmittingTool` and `any ForkableTool` from an `any Tool` existential; `connecting(fakeSink)` returns a usable tool copy — verified by tests performing exactly those casts, no ShellTool-specific knowledge
- [ ] Two `connecting` copies over one `make()` result share command history (a command run via copy A is visible via `list processes` through copy B) while posting events to their own sinks only; a `forked()` copy likewise shares history (one shared machine)
- [ ] With a sink-bound copy: a detached command posts `.completed` exactly once with correct status/exitCode/lineCount; a killed and a timed-out detached command each post `.completed` with their status
- [ ] A command finishing within the wait window posts no events; the un-instanced original posts nothing anywhere
- [ ] `.progress` events respect the throttle interval (assert via injected interval, not wall-clock 5s waits)
- [ ] Sink captured at operation start: re-instancing (or discarding) the copy after a command detaches does not change where that command's events go
- [ ] Public API documented per the doc-coverage gate, including the v1 fork stance

## Tests
- [ ] `Tests/ShellToolTests/ShellRunnerTests.swift` (or new `ShellEventsTests.swift`) — cast-and-connecting/forked from `any Tool`; shared-state/independent-route tests; fake sink actor records events; all criteria above
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running