// `KillProcess` — the `kill process` operation.
//
// A direct behavioral port of the Rust `swissarmyhammer-tools`
// `shell/kill_process`. It SIGKILLs a still-running command's process group by
// its stored pid — via `ShellState.killProcess`, which `killpg`s the group and
// flips the record to `.killed` — then reports the command and the lines
// captured so far.
//
// An unknown or already-finished id has no registered running process, so
// `ShellState.killProcess` throws `noRunningProcess`. That is an EXPECTED
// failure the model should be able to recover from within the turn, so it is
// **returned** as a corrective message rather than thrown: `OperationTool`
// surfaces a thrown `execute(in:)` as a fatal `OperationError.executionFailed`
// that aborts the turn, but returns the operation's output to the model.
// Carrying the correction in the output (`KillOutput.corrective`) therefore
// matches the framework's "return, don't throw" design, exactly as
// `ExecuteCommand` does for a policy-rejected command.
//
// The kill returns promptly — `killpg` plus a handful of O(small) actor
// mutations — so it takes effect well within a long-running command's lifetime
// (risk plan §7.3); the actor is never held while a command runs.

import FoundationModels
import Foundation
import Operations

/// Kills a running command by id, sending `SIGKILL` to its process group
/// immediately.
@Generable
@Operation(
    verb: "kill",
    noun: "process",
    description: "Kill a running command by ID. Sends SIGKILL immediately."
)
internal struct KillProcess {
    @Guide(description: "Command ID to kill")
    @OperationParam(short: "i")
    var id: Int
}

extension KillProcess {
    /// SIGKILL the process group of the command with `id`, flip its record to
    /// `killed`, and report the command and lines captured. An unknown or
    /// already-finished id (no registered running process) short-circuits to a
    /// corrective message instead of throwing.
    func execute(in context: ShellContext) async throws -> KillOutput {
        do {
            let record = try await context.state.killProcess(commandID: id)
            return .killed(
                KillResult(id: record.id, command: record.command, linesCaptured: record.lineCount))
        } catch let error as ShellStateError {
            // Unknown or already-finished id: no registered running process.
            // Return the correction rather than throw, so the model can recover
            // within the turn.
            return .corrective(error.description)
        }
    }
}

/// The output of `KillProcess`: either the structured result of a successful
/// kill, or a corrective message when the id had no running process.
///
/// Encoded so the fused tool's `String` output carries either the result
/// object or the bare correction text — the model reads and acts on either.
/// Same shape as `ExecuteOutput`.
internal enum KillOutput: Encodable, Sendable, Equatable {
    /// The command was running and was killed; carries its structured result.
    case killed(KillResult)
    /// The id had no running process; carries the corrective message.
    case corrective(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .killed(let result):
            try container.encode(result)
        case .corrective(let message):
            try container.encode(message)
        }
    }
}

/// The structured result of a successful `kill process`.
internal struct KillResult: Encodable, Sendable, Equatable {
    /// The killed command's 1-based id.
    let id: Int
    /// The command string that was killed.
    let command: String
    /// Stored output lines recorded for the command at the moment it was
    /// killed. Output is recorded incrementally as it streams in (see
    /// `ShellRunner`'s single-consumer flush), so a command killed mid-stream
    /// reports whatever lines had already landed in `ShellState` before the
    /// kill — no longer always `0`.
    let linesCaptured: Int
}
