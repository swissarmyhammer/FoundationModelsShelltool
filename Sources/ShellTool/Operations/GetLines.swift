// `GetLines` — the `get lines` operation.
//
// A direct behavioral port of the Rust `swissarmyhammer-tools`
// `shell/get_lines`. It reads a stored command's output back from the
// `.shell/log` — via `ShellState.getLines`, which scans only this session's
// lines for the given command and honors an optional `start...end` bound — and
// returns them as line-number-prefixed strings alongside the covered range.
//
// An unknown `commandID` is NOT an error: `ShellState.getLines` yields an empty
// result for an id it never recorded (parity with the Rust op, which reports
// "No output lines found" rather than failing), so this op returns an empty
// `LineRange` rather than a correction or a throw. The only corrective path is
// the framework-level "missing required `commandId`" one, which `OperationTool`
// returns before `execute(in:)` is ever reached.

import FoundationModels
import Foundation
import Operations

/// Retrieves a stored command's output lines by number range — all of them by
/// default, or a `start...end` slice when bounded.
@Generable
@Operation(
    verb: "get",
    noun: "lines",
    description: "Retrieve specific lines from a command's output by range"
)
internal struct GetLines {
    @Guide(description: "Which command's output to retrieve lines from")
    @OperationParam(short: "i")
    var commandID: Int

    @Guide(description: "Start line number (default: 1)")
    @OperationParam(short: "s")
    var start: Int?

    @Guide(description: "End line number (default: last line)")
    @OperationParam(short: "e")
    var end: Int?
}

extension GetLines {
    /// Read the requested lines from `context`'s history and format them.
    ///
    /// Delegates to `ShellState.getLines`, which defaults `start` to `1` and
    /// `end` to the last stored line, and yields an empty result for an unknown
    /// `commandID`. The lines are formatted `"{lineNumber}: {text}"` — the same
    /// numbering `execute command` echoes — and the covered `first`/`last` line
    /// numbers are reported alongside (`0` each when the result is empty).
    func execute(in context: ShellContext) async throws -> LineRange {
        let lines = try await context.state.getLines(commandID: commandID, start: start, end: end)
        return LineRange(
            commandID: commandID,
            first: lines.first?.lineNumber ?? 0,
            last: lines.last?.lineNumber ?? 0,
            lines: lines.map { "\($0.lineNumber): \($0.text)" }
        )
    }
}

/// The structured result of `get lines`: the covered line-number range and the
/// line-number-prefixed lines themselves.
///
/// For an unknown `commandID` (or a range covering no stored lines) the result
/// is empty: `first` and `last` are both `0` and `lines` is empty — parity with
/// the Rust op, which reports no output rather than failing.
internal struct LineRange: Encodable, Sendable, Equatable {
    /// The command whose output these lines came from.
    let commandID: Int
    /// The first covered line number, or `0` when the result is empty.
    let first: Int
    /// The last covered line number, or `0` when the result is empty.
    let last: Int
    /// The retrieved lines, each formatted `"{lineNumber}: {text}"`.
    let lines: [String]

    /// The Swift property `commandID` uses correct acronym casing, but its
    /// encoded JSON key stays `commandId` — the wire contract the model reads
    /// and the JSON-shape acceptance criterion pins. The remaining keys keep
    /// their synthesized names. (Same technique as `ExecuteResult`.)
    enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case first
        case last
        case lines
    }
}
