// `ShellContext` — the shared environment every shell operation runs against.
//
// Bundles the three collaborators the operations need: the `ShellState` actor
// (command history and the `.shell/log` store), a `ShellRunner` that spawns and
// supervises children into that same state, and the `ShellPolicy` that vets a
// command, its environment, and its working directory before it runs.
//
// It plays the role `NotesContext` does in the upstream example: it is only
// public because it is `OperationTool`'s generic `Context` parameter — part of
// a fused tool's public `OperationTool<ShellContext>` type — so Swift requires
// it to be at least as visible as any public function naming that type. Its
// members stay `internal`; nothing outside this module constructs or inspects a
// `ShellContext` directly.
//
// **Event emission (`EventEmittingContext`).** Conforming turns the fused
// `shell` `OperationTool<ShellContext>` into an `EventEmittingTool` (see
// `OperationTool`'s conditional conformance, activated automatically — nothing
// in `ShellTool.swift` hand-rolls it). `operationEventSink` defaults to `nil`
// (no sink connected, zero behavior change for every existing embedder), and
// `connecting(_:)` returns a copy sharing `state`/`runner`/`policy` verbatim
// with only the sink replaced — see `ShellRunner`'s detached-event posting for
// the capture-at-start rule this enables.
//
// **v1 fork stance (pinned).** `ShellContext` deliberately does NOT conform to
// `ForkableContext`. `OperationTool` still conforms to `ForkableTool`
// unconditionally, so `forked()` is available — it just falls back to sharing
// `context` unchanged (per `OperationTool.forked()`'s doc comment), still
// sharing the same reference-typed `state`/`runner`. One shared machine: a
// forked copy and its parent see the same command history, and each session's
// events route through its own `connecting(_:)` copy. Branched per-fork history
// is a possible later tool-internal upgrade (give `ShellContext` its own
// `ForkableContext` conformance then) — not built here.

import Foundation
import Operations

/// The shared environment every shell operation's `execute(in:)` runs against:
/// a `ShellState` actor, a `ShellRunner` over that state, and a `ShellPolicy`.
public struct ShellContext: Sendable, EventEmittingContext {
    /// The history actor commands are recorded into and read back from.
    let state: ShellState
    /// The runner that spawns children and streams their output into `state`.
    let runner: ShellRunner
    /// The security policy each command is validated against before it runs.
    let policy: ShellPolicy

    /// The sink this context's operations post `OperationEvent`s through, or
    /// `nil` (the default) when none is connected — posting is then a safe
    /// no-op, so an embedder that never calls `connecting(_:)` sees zero
    /// behavior change. See `EventEmittingContext` and this file's header for
    /// the v1 subscription/fork stance.
    public let operationEventSink: (any OperationEventSink)?

    /// Bundle an existing `state` with a `policy`, building a `ShellRunner` over
    /// that same state.
    ///
    /// - Parameters:
    ///   - state: The history actor to record into; the runner is built over it
    ///     so the operation can read a finished command's stored lines back.
    ///   - policy: The security policy to validate commands against. Defaults to
    ///     a fresh `ShellPolicy()` over the standard user/project overlays.
    ///   - maxOutputSize: The runner's total captured-output cap in bytes,
    ///     shared across stdout and stderr. Defaults to
    ///     `ShellRunner.defaultMaxOutputSize`.
    ///   - operationEventSink: The sink this context's operations post events
    ///     through. Defaults to `nil` (no sink connected). A caller building a
    ///     context directly does not normally pass this — a session host wires
    ///     it up via `connecting(_:)` instead (see `EventEmittingTool`'s
    ///     "hosts connect, users don't" contract).
    init(
        state: ShellState,
        policy: ShellPolicy = ShellPolicy(),
        maxOutputSize: Int = ShellRunner.defaultMaxOutputSize,
        operationEventSink: (any OperationEventSink)? = nil
    ) {
        self.state = state
        self.runner = ShellRunner(state: state, maxOutputSize: maxOutputSize)
        self.policy = policy
        self.operationEventSink = operationEventSink
    }

    /// Full-field initializer backing `connecting(_:)`: rebuilds a context
    /// sharing the receiver's already-built `state`, `runner`, and `policy`
    /// verbatim — in particular the same `ShellRunner` (so a copy's detached
    /// commands still supervise into the identical `RunSupervisor` and
    /// `ProcessRegistry`) — with only `operationEventSink` replaced.
    private init(state: ShellState, runner: ShellRunner, policy: ShellPolicy, operationEventSink: (any OperationEventSink)?) {
        self.state = state
        self.runner = runner
        self.policy = policy
        self.operationEventSink = operationEventSink
    }

    /// Returns a copy of this context routed to `sink`, sharing `state`,
    /// `runner`, and `policy` with the receiver — see `EventEmittingContext`'s
    /// capture-at-start rule and this file's header for the v1
    /// subscription/fork stance.
    ///
    /// - Parameter sink: The sink the returned context's operations post to.
    /// - Returns: A copy of the receiver sharing all state, routed to `sink`.
    public func connecting(_ sink: any OperationEventSink) -> ShellContext {
        ShellContext(state: state, runner: runner, policy: policy, operationEventSink: sink)
    }
}
