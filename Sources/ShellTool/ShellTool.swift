// `ShellTool` — the fused FoundationModels shell tool.
//
// Fuses the five shell operations — `ExecuteCommand`, `ListProcesses`,
// `KillProcess`, `GrepHistory`, `GetLines` — into a single
// `OperationTool<ShellContext>` via `make(context:)`, the direct analogue of
// the upstream `NotesTool.make()` worked example. It is the library's entry
// point: a caller builds a `ShellContext`, calls `make(context:)`, and drops
// the returned tool into a `LanguageModelSession(tools:)` list (or an
// `OperationCLIDriver`).
//
// The tool's name and description match the Rust `swissarmyhammer-tools`
// `ShellExecuteTool` verbatim, and the empty-`op` default (`""` → `execute
// command` in the Rust dispatch `match`) is expressed through the upstream
// resolver's opt-in `inferOp` inference hook rather than any hand-rolled
// wiring. Per-op requiredness, snake_case/camelCase key normalization, and the
// flat-union schema all come from the upstream `OperationTool`/
// `OperationResolver`/`SchemaFusion` machinery.

import Foundation
import FoundationModels
import Operations

/// The fused `shell` `OperationTool`'s public factory and shared naming.
///
/// The full-stack analogue of the upstream `NotesTool`: the five `@Operation`
/// operations fused by `OperationTool` and driven by both an
/// `OperationCLIDriver` and a `LanguageModelSession`.
public enum ShellTool {
    /// The fused tool's model- and CLI-facing name.
    ///
    /// Parity with the Rust `ShellExecuteTool::name`.
    public static let name = "shell"

    /// A human- and model-facing summary of the fused tool, byte-identical to the Rust `ShellExecuteTool::description`.
    public static let description =
        "Virtual shell with history and process management. Execute commands, grep output history, and manage running processes."

    /// Builds the fused `shell` tool over a freshly assembled default `ShellContext`.
    ///
    /// The contextless entry point the `shell-demo` executable (and any other
    /// embedder without `@testable` access) uses, since `ShellContext` and
    /// `ShellState` are module-internal and cannot be constructed from outside.
    ///
    /// The context bundles a `ShellState` over `preferredDirectory` and a
    /// default `ShellPolicy` (the stacked builtin/user/project overlays). This
    /// is the direct analogue of the upstream no-arg `NotesTool.make()`, which
    /// likewise assembles its own `NotesContext`; the one added parameter lets
    /// an embedder (or a hermetic test) point the `.shell` store somewhere
    /// other than the working directory.
    ///
    /// - Parameter preferredDirectory: The `.shell` store's directory. When
    ///   `nil` (the default) the store is rooted at `<cwd>/.shell`, falling
    ///   back to a unique temp directory when the working directory is
    ///   unwritable — the real-world location the executable uses. When
    ///   non-`nil`, that directory is used as the store directly.
    /// - Returns: The fused tool, ready to drive both an `OperationCLIDriver`
    ///   and a `LanguageModelSession`.
    /// - Throws: `ShellStateError.logCreationFailed` if the store's log file
    ///   cannot be created; rethrows `make(context:)`'s schema-fusion errors.
    public static func make(preferredDirectory: URL? = nil) throws -> OperationTool<ShellContext> {
        let state = try preferredDirectory.map { try ShellState(preferredDirectory: $0) } ?? ShellState()
        return try make(context: ShellContext(state: state))
    }

    /// Builds the fused `shell` tool over `context`.
    ///
    /// Fuses the five operations — `execute command`, `list processes`, `kill
    /// process`, `grep history`, `get lines` — into one
    /// `OperationTool<ShellContext>`, sharing `context` so every op reads and
    /// records into the same `ShellState`. The resolver is given an `inferOp`
    /// hook returning `"execute command"`, so a payload that omits `op`
    /// entirely resolves to the execute-command operation — the upstream
    /// expression of the Rust dispatch's `"execute command" | "" =>` empty-op
    /// default.
    ///
    /// Exposed as a factory rather than a stored singleton because
    /// `OperationTool.init` throws, and because each `ShellContext` carries a
    /// distinct `ShellState` (its own `.shell/log` store) the caller owns and
    /// supplies.
    ///
    /// - Parameter context: The shared environment every operation's
    ///   `execute(in:)` runs against — the `ShellState`, `ShellRunner`, and
    ///   `ShellPolicy` the caller assembled.
    /// - Returns: The fused tool, ready to drive both an `OperationCLIDriver`
    ///   and a `LanguageModelSession`.
    /// - Throws: `SchemaFusionError.reservedParameterName` if the fused schema
    ///   collides with the `op` discriminator (not expected for this fixed
    ///   operation set, but propagated per `OperationTool.init`'s contract);
    ///   rethrows `GenerationSchema.SchemaError` on any other schema-fusion
    ///   failure.
    public static func make(context: ShellContext) throws -> OperationTool<ShellContext> {
        try OperationTool(
            name: name,
            description: description,
            context: context,
            operations: [
                AnyOperation(ExecuteCommand.self),
                AnyOperation(ListProcesses.self),
                AnyOperation(KillProcess.self),
                AnyOperation(GrepHistory.self),
                AnyOperation(GetLines.self),
            ],
            resolver: OperationResolver(inferOp: { _ in ExecuteCommand.opString })
        )
    }
}
