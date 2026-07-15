// `ListProcesses` — the `list processes` operation.
//
// A direct behavioral port of the Rust `swissarmyhammer-tools`
// `shell/list_processes`. It reads the full command history back from the
// `ShellState` actor and returns it as an array of structured rows — one per
// recorded command, in start order — carrying the same fields the Rust text
// table renders (id, status, exit code, line count, wall-clock start,
// duration, command).
//
// The Rust op emits a preformatted text table; this port returns a small
// `Encodable` array instead (plan §"Typed outputs"), which the fused tool
// JSON-encodes without the double-escaping a wrapped text block would incur.
//
// `ShellState.listCommands` is O(small) and never waits on a child, so this op
// answers promptly even while another `execute command` is mid-flight — the
// actor is never held during a running command.

import FoundationModels
import Foundation
import Operations

/// Lists every command in this session's history with its status, exit code,
/// line count, start time, duration, and command string.
@Generable
@Operation(
    verb: "list",
    noun: "processes",
    description:
        "Show all commands with status, exit code, line count, start time, duration, and command"
)
internal struct ListProcesses {
}

extension ListProcesses {
    /// Read the full command history from `context` and map each record to a
    /// wire `ProcessRow`, in start order.
    func execute(in context: ShellContext) async throws -> ListProcessesResult {
        let records = await context.state.listCommands()
        return ListProcessesResult(processes: records.map(Self.row(for:)))
    }

    /// Project a `ShellState` record onto its wire row: status and exit code
    /// straight through, the wall-clock start as ISO-8601, and the elapsed
    /// duration in the Rust table's `"1.5s"` / `"1.5s+"` form.
    private static func row(for record: CommandRecord) -> ProcessRow {
        ProcessRow(
            id: record.id,
            status: record.status.rawValue,
            exitCode: record.exitCode,
            lineCount: record.lineCount,
            startedAt: record.startedAtWall.ISO8601Format(),
            duration: durationString(for: record),
            command: record.command
        )
    }

    /// A record's elapsed run time as `"{seconds}.{tenths}s"`, with a trailing
    /// `+` while the command is still running — parity with the Rust table's
    /// `format!("{:.1}s", …)` / `format!("{:.1}s+", …)`. `Duration.components`
    /// is seconds plus attoseconds (`1e18` attoseconds per second).
    private static func durationString(for record: CommandRecord) -> String {
        let (seconds, attoseconds) = record.duration.components
        let secs = Double(seconds) + Double(attoseconds) / 1e18
        let formatted = String(format: "%.1fs", secs)
        return record.status == .running ? formatted + "+" : formatted
    }
}

/// One row of `list processes`: a single command's history record, rendered
/// with the field names the model reads.
///
/// `exitCode` is optional and omitted from the encoded JSON when `nil` (the
/// synthesized `Encodable` uses `encodeIfPresent` for optionals), so it appears
/// only once the command has a known exit code — never while it is still
/// `running`, nor for a `killed` command (which has none).
internal struct ProcessRow: Encodable, Sendable, Equatable {
    /// The command's `ShellState`-assigned 1-based id.
    let id: Int
    /// Current status: `running`, `completed`, `killed`, or `timed_out`.
    let status: String
    /// Process exit code once known; `nil` (and omitted) while running or killed.
    let exitCode: Int?
    /// Count of stored output lines recorded for this command so far.
    let lineCount: Int
    /// Wall-clock start time, ISO-8601 formatted.
    let startedAt: String
    /// Elapsed run time, formatted like the Rust table: `"1.5s"` once finished,
    /// `"1.5s+"` (a trailing `+`) while the command is still running.
    let duration: String
    /// The command string as submitted.
    let command: String
}

/// The result of `list processes`: the history rows as a bare JSON array.
///
/// A named wrapper — in the same family as `ExecuteResult` and `KillResult` —
/// whose custom encoding emits the underlying `processes` array directly, so
/// the wire shape is a top-level array of `ProcessRow`s rather than an object
/// wrapping one (plan §3: "array of record rows"). The technique mirrors
/// `ExecuteOutput`'s `singleValueContainer` encoding.
internal struct ListProcessesResult: Encodable, Sendable, Equatable {
    /// The history rows, in start order.
    let processes: [ProcessRow]

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(processes)
    }
}
