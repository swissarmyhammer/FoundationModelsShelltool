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

import Foundation

/// The shared environment every shell operation's `execute(in:)` runs against:
/// a `ShellState` actor, a `ShellRunner` over that state, and a `ShellPolicy`.
public struct ShellContext: Sendable {
    /// The history actor commands are recorded into and read back from.
    let state: ShellState
    /// The runner that spawns children and streams their output into `state`.
    let runner: ShellRunner
    /// The security policy each command is validated against before it runs.
    let policy: ShellPolicy

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
    init(
        state: ShellState,
        policy: ShellPolicy = ShellPolicy(),
        maxOutputSize: Int = ShellRunner.defaultMaxOutputSize
    ) {
        self.state = state
        self.runner = ShellRunner(state: state, maxOutputSize: maxOutputSize)
        self.policy = policy
    }
}
