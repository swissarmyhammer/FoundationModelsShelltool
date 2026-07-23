---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: 'OperationTool: standard progress/completion event vocabulary and EventEmitting protocol'
---
## What

**Sibling-repo task — work happens in `/Users/wballard/github/swissarmyhammer/FoundationModelsOperationTool`; build and test there.**

Make progress/completion events a standard capability of operation tools, so any session host that knows one protocol can receive events from any fused tool. This is the seam the shell tool posts through and the Router connects to — neither ever depends on the other.

Design and land in that package:
- `OperationEvent` (`Codable`, `Sendable`): `tool` (fused tool name), `op` (operation string), `correlationID` (tool-assigned, e.g. the shell's commandID), `kind` (`.progress` / `.completed`), and a small `Codable` detail payload (propose a JSON-string `detail` the emitting tool owns; refine against the package's conventions).
- `OperationEventSink` (`Sendable` protocol): `func post(_ event: OperationEvent) async`.
- `EventEmittingTool` protocol with `func connect(_ sink: any OperationEventSink)`. **Usage contract (pinned): `connect` is host-internal machinery, never an end-user call.** A host receives tools as an ordinary `[any Tool]` list (e.g. a session's `tools:` parameter), discovers emitters by conformance cast (`tool as? any EventEmittingTool`), and connects them itself during setup — implementing the protocol IS the subscription; nobody "remembers to connect". The protocol must therefore be discoverable from an `any Tool` existential (design the conformance so the cast works on the concrete fused-tool type).
- Design how `OperationTool<Context>` plumbs a connected sink through to operations' `execute(in:)` contexts (e.g. an opt-in context protocol with a mutable sink holder, since contexts are value types shared across ops). A tool instance connects to one sink — no fan-out (document; don't build speculatively). Follow the package's existing resolver/fusion design idioms and its DESIGN_NOTES/doc-coverage conventions.

## Acceptance Criteria
- [ ] Given a `[any Tool]` list containing a fused `OperationTool` whose context opted in, a host can discover it via `as? any EventEmittingTool` and connect a sink — verified by a test that does exactly this cast-and-connect over a mixed list
- [ ] An operation's `execute(in:)` can post `.progress`/`.completed` events that arrive at the connected sink with tool/op/correlationID intact
- [ ] A tool with no connected sink posts into the void safely (no error, no retention of events)
- [ ] Public API documented per that repo's doc-coverage gate, including the "hosts connect, users don't" contract

## Tests
- [ ] Unit tests in `FoundationModelsOperationTool`'s test target: cast-and-connect over a mixed `[any Tool]` list + post round-trip through a fake sink actor; no-sink no-op; event Codable round-trip
- [ ] `swift test` fully green in `/Users/wballard/github/swissarmyhammer/FoundationModelsOperationTool`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.