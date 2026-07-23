// `ShellEventsTests` — the `EventEmittingTool`/`ForkableTool` surface.
//
// Exercises the acceptance criteria pinned by kanban task e8sarnb: `make(...)`
// is discoverable as both `any EventEmittingTool` and `any ForkableTool` via a
// cast from `any Tool`; `connecting(_:)` copies share command history while
// routing events independently; a `forked()` copy shares history too; a
// sink-bound copy posts `.completed` exactly once for a detached command with
// the right status/exitCode/lineCount for each terminal status; a command that
// finishes within the wait window posts nothing; and the sink is captured at
// operation start, surviving re-instancing.
//
// These tests deliberately drive everything through `ShellTool.make(...)` plus
// casts from `any Tool` — no `ShellTool`-specific knowledge of how the
// conformances are wired — mirroring the upstream `EventEmittingToolTests`/
// `ForkableToolTests` fixtures this package's dependency ships.

import Foundation
import FoundationModels
import Operations
import Testing

@testable import ShellTool

/// Collects every event posted to it, for assertion — the shell-tool-local
/// analogue of the upstream `Operations` package's own `FakeEventSinkActor`
/// test fixture. Not `private` so `ShellRunnerTests` can reuse it too.
actor FakeShellEventSinkActor: OperationEventSink {
    private(set) var events: [OperationEvent] = []

    func post(_ event: OperationEvent) async {
        events.append(event)
    }
}

@Suite struct ShellEventsTests {

    /// Build a fresh `ShellContext` rooted at a unique temp `.shell` store,
    /// with a builtin-only policy (no `~/.shell` or project overlay) — mirrors
    /// `FusionTests.makeTool`'s harness.
    private static func makeContext() throws -> ShellContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellevents-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        return ShellContext(state: state, policy: policy)
    }

    /// Poll `sink.events` until it has at least `count` entries or `deadline`
    /// passes; returns whatever was observed last.
    private static func waitForEvents(
        _ sink: FakeShellEventSinkActor, count: Int, deadline: Duration
    ) async -> [OperationEvent] {
        let clock = ContinuousClock()
        let start = clock.now
        var events = await sink.events
        while events.count < count, clock.now - start < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            events = await sink.events
        }
        return events
    }

    /// Poll `state.getLines(commandID:)` until it has at least one line or
    /// `deadline` passes — proof the child has actually spawned and
    /// registered its pid, so a subsequent `kill process` races against a
    /// real running process rather than a not-yet-registered one. Mirrors
    /// `ShellRunnerTests`' identical polling pattern for the same reason.
    private static func waitForFirstLine(in state: ShellState, commandID: Int, deadline: Duration) async {
        let clock = ContinuousClock()
        let start = clock.now
        var lines = (try? await state.getLines(commandID: commandID)) ?? []
        while lines.isEmpty, clock.now - start < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            lines = (try? await state.getLines(commandID: commandID)) ?? []
        }
    }

    // MARK: - Discoverability: make() casts to both capability protocols

    @Test func makeReturnsAToolThatCastsToBothEventEmittingToolAndForkableTool() throws {
        let context = try Self.makeContext()
        let tool: any Tool = try ShellTool.make(context: context)

        #expect(tool as? any EventEmittingTool != nil)
        #expect(tool as? any ForkableTool != nil)
    }

    // MARK: - connecting(_:): shared history, independent event routes

    /// Two `connecting(_:)` copies over one `make()` result share command
    /// history (a command run via copy A is visible through copy B's `list
    /// processes`) while each routes its own events to its own sink only —
    /// proving both halves of the subscription contract together, mirroring
    /// the upstream `connectingTwoSinksPostIndependentlyWhileSharing…` test.
    @Test func connectingTwoCopiesShareCommandHistoryButRouteEventsIndependently() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let emitting = baseTool as? any EventEmittingTool else {
            Issue.record("expected any EventEmittingTool conformance")
            return
        }
        let sinkA = FakeShellEventSinkActor()
        let sinkB = FakeShellEventSinkActor()
        guard let toolA = emitting.connecting(sinkA) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }
        guard let toolB = emitting.connecting(sinkB) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }

        // A command that outlives its wait window detaches and (eventually)
        // posts its `.completed` event to whichever copy's sink started it.
        let result = try await toolA.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "sleep 0.3", "waitSeconds": 0,
            ]))
        #expect(result.contains("\"status\":\"running\""))

        let eventsA = await Self.waitForEvents(sinkA, count: 1, deadline: .seconds(5))
        #expect(eventsA.map(\.kind) == [.completed])
        #expect(eventsA.first?.correlationID == "1")

        let eventsB = await sinkB.events
        #expect(eventsB.isEmpty, "sinkB must not receive events for a command started through sinkA's copy")

        // Shared history: the command run through copy A is visible through
        // copy B's `list processes` — one shared `ShellState`/supervisor.
        let listed = try await toolB.call(arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(listed.contains("\"id\":1"))
        #expect(listed.contains("sleep 0.3"))
    }

    // MARK: - forked(): shares the engine (one shared machine, v1 stance)

    /// The blanket `forked()` default shares command history with the
    /// receiver — `ShellContext` deliberately does not conform to
    /// `ForkableContext` (see `ShellContext.swift`'s header), so `forked()`
    /// falls back to sharing `context` unchanged, still sharing the same
    /// reference-typed `state`/`runner`.
    @Test func forkedCopySharesCommandHistoryWithTheParent() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let forkable = baseTool as? any ForkableTool else {
            Issue.record("expected any ForkableTool conformance")
            return
        }
        guard let forked = forkable.forked() as? OperationTool<ShellContext> else {
            Issue.record("forked() did not return an OperationTool<ShellContext>")
            return
        }
        guard let parent = baseTool as? OperationTool<ShellContext> else {
            Issue.record("make() did not return an OperationTool<ShellContext>")
            return
        }

        _ = try await parent.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo from-parent"]))

        let listedViaFork = try await forked.call(arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(listedViaFork.contains("\"id\":1"))
        #expect(listedViaFork.contains("echo from-parent"))
    }

    // MARK: - Sink-bound copy: .completed exactly once, per terminal status

    /// A detached command that finishes on its own posts `.completed` exactly
    /// once, carrying its command string, `completed` status, exit code, and
    /// line count.
    @Test func detachedCommandThatCompletesPostsCompletedExactlyOnceWithCorrectDetails() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let emitting = baseTool as? any EventEmittingTool else {
            Issue.record("expected any EventEmittingTool conformance")
            return
        }
        let sink = FakeShellEventSinkActor()
        guard let tool = emitting.connecting(sink) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }

        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "echo detached-echo", "waitSeconds": 0,
            ]))

        let events = await Self.waitForEvents(sink, count: 1, deadline: .seconds(5))
        #expect(events.count == 1, "expected exactly one event, got \(events.count)")
        guard let event = events.first else { return }
        #expect(event.tool == "shell")
        #expect(event.op == "execute command")
        #expect(event.correlationID == "1")
        #expect(event.kind == .completed)
        #expect(event.detail.contains("\"command\":\"echo detached-echo\""))
        #expect(event.detail.contains("\"status\":\"completed\""))
        #expect(event.detail.contains("\"exitCode\":0"))
        #expect(event.detail.contains("\"lines\":1"))

        // Stays exactly one even after giving any stray extra post a chance
        // to land.
        try? await Task.sleep(for: .milliseconds(200))
        let finalEvents = await sink.events
        #expect(finalEvents.count == 1)
    }

    /// A detached command killed via `kill process` posts `.completed` with
    /// `status: "killed"` — the authoritative `ShellState` record, not the
    /// runner's own outcome, which would otherwise report `completed`.
    @Test func killedDetachedCommandPostsCompletedWithKilledStatus() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let emitting = baseTool as? any EventEmittingTool else {
            Issue.record("expected any EventEmittingTool conformance")
            return
        }
        let sink = FakeShellEventSinkActor()
        guard let tool = emitting.connecting(sink) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }

        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "echo alive; sleep 30", "waitSeconds": 0,
            ]))
        // Wait for the child to have actually spawned and registered its pid
        // (proven by its first line landing) before killing — otherwise
        // `kill process` can race a not-yet-registered process and no-op.
        await Self.waitForFirstLine(in: context.state, commandID: 1, deadline: .seconds(3))
        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "kill process", "id": 1]))

        let events = await Self.waitForEvents(sink, count: 1, deadline: .seconds(5))
        #expect(events.count == 1, "expected exactly one event, got \(events.count)")
        guard let event = events.first else { return }
        #expect(event.kind == .completed)
        #expect(event.detail.contains("\"status\":\"killed\""))
    }

    /// A detached command that exceeds its own `timeout` posts `.completed`
    /// with `status: "timed_out"`.
    @Test func timedOutDetachedCommandPostsCompletedWithTimedOutStatus() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let emitting = baseTool as? any EventEmittingTool else {
            Issue.record("expected any EventEmittingTool conformance")
            return
        }
        let sink = FakeShellEventSinkActor()
        guard let tool = emitting.connecting(sink) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }

        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "sleep 30", "timeout": 1, "waitSeconds": 0,
            ]))

        let events = await Self.waitForEvents(sink, count: 1, deadline: .seconds(5))
        #expect(events.count == 1, "expected exactly one event, got \(events.count)")
        guard let event = events.first else { return }
        #expect(event.kind == .completed)
        #expect(event.detail.contains("\"status\":\"timed_out\""))
        #expect(event.detail.contains("\"exitCode\":-1"))
    }

    // MARK: - Finishing within the wait window posts nothing

    /// A command that finishes on its own well inside `waitSeconds` posts no
    /// events at all — its result was already delivered in-band.
    @Test func commandFinishingWithinTheWaitWindowPostsNoEvents() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let emitting = baseTool as? any EventEmittingTool else {
            Issue.record("expected any EventEmittingTool conformance")
            return
        }
        let sink = FakeShellEventSinkActor()
        guard let tool = emitting.connecting(sink) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }

        let result = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo quick"]))
        #expect(result.contains("\"status\":\"completed\""))

        // Give any stray background posting a chance to land before asserting
        // the negative.
        try? await Task.sleep(for: .milliseconds(200))
        let events = await sink.events
        #expect(events.isEmpty, "a command finishing within the wait window must post no events")
    }

    /// The un-instanced original `make()` result (never `connecting(_:)`ed to
    /// anything) has no sink at all, so a detached command run through it
    /// posts nothing anywhere — there is nothing to assert against, only that
    /// dispatch itself still works normally.
    @Test func unconnectedOriginalToolDetachesNormallyWithNoSinkToPostTo() async throws {
        let context = try Self.makeContext()
        let tool = try ShellTool.make(context: context)

        let result = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "sleep 30", "waitSeconds": 0,
            ]))
        #expect(result.contains("\"status\":\"running\""))

        _ = try await tool.call(arguments: GeneratedContent(properties: ["op": "kill process", "id": 1]))
    }

    // MARK: - Capture-at-start: re-instancing after detach doesn't redirect events

    /// The sink is captured once, at operation start: discarding the
    /// `connecting(_:)` copy that started a detached command — and building a
    /// fresh, differently-routed copy from the same base tool — does not
    /// redirect that command's already-in-flight events.
    @Test func sinkCapturedAtOperationStartSurvivesDiscardingTheStartingCopy() async throws {
        let context = try Self.makeContext()
        let baseTool: any Tool = try ShellTool.make(context: context)
        guard let emitting = baseTool as? any EventEmittingTool else {
            Issue.record("expected any EventEmittingTool conformance")
            return
        }
        let sinkA = FakeShellEventSinkActor()

        // Start the detached command through a `connecting(sinkA)` copy, then
        // let that copy go out of scope entirely — nothing but `context`'s
        // shared state and the fire-and-forget posting task survive.
        do {
            guard let toolA = emitting.connecting(sinkA) as? OperationTool<ShellContext> else {
                Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
                return
            }
            let result = try await toolA.call(
                arguments: GeneratedContent(properties: [
                    "op": "execute command", "command": "echo captured-at-start", "waitSeconds": 0,
                ]))
            #expect(result.contains("\"status\":\"running\""))
        }

        // Re-instance the base tool to a different sink after the fact —
        // must not steal or duplicate the already-detached command's events.
        let sinkB = FakeShellEventSinkActor()
        guard let toolB = emitting.connecting(sinkB) as? OperationTool<ShellContext> else {
            Issue.record("connecting(_:) did not return an OperationTool<ShellContext>")
            return
        }
        _ = toolB

        let eventsA = await Self.waitForEvents(sinkA, count: 1, deadline: .seconds(5))
        #expect(eventsA.map(\.kind) == [.completed])

        let eventsB = await sinkB.events
        #expect(eventsB.isEmpty, "re-instancing to a new sink must not redirect an already-detached command's events")
    }
}
