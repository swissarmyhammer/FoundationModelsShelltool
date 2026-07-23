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
// `LineRange` rather than a correction or a throw.
//
// `waitSeconds` turns the naive "call `get lines` again and again" busy-poll
// into a long-poll: when the requested range comes back empty and the
// command's record is still `running`, `execute(in:)` itself re-reads
// `context.state` on a short cadence until a line lands in range, the
// command leaves `running`, or `waitSeconds`'s deadline elapses — instead of
// returning empty and making the model burn a tool call re-asking every time.
// The poll loop lives here, in the op, and never on `ShellState`: the actor's
// pinned contract is "state is brief, execution is long — every method
// O(small)" (see `Sources/ShellTool/ShellState.swift`'s file header), and a
// multi-second wait with a re-read per iteration is exactly what that
// contract forbids inside an actor method. `LineRange.status` is how the
// model learns whether a poll loop should keep going: present (and
// `"running"`) while it should, any other value (or a key absent entirely,
// for an unknown `commandID`) once it shouldn't.
//
// A negative `waitSeconds` is the one corrective path this op returns
// (mirroring `ExecuteOutput.corrective`/`KillOutput.corrective`); every other
// outcome — including the unknown-`commandID`/empty-range case above — stays
// a normal, non-corrective, non-thrown result.

import FoundationModels
import Foundation
import Operations

/// Retrieves a stored command's output lines by number range — all of them by
/// default, or a `start...end` slice when bounded — optionally long-polling
/// while the command is still running and the requested range is empty.
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

    @Guide(
        description:
            "Seconds to wait for lines to appear when the requested range is empty and the command is still running (optional, default: return immediately)"
    )
    var waitSeconds: Int?
}

extension GetLines {
    /// How often `execute(in:)` re-reads `context` while long-polling: short
    /// enough that a newly arrived line is noticed promptly, long enough not
    /// to busy-spin the `ShellState` actor.
    static let pollInterval: Duration = .milliseconds(200)

    /// Read the requested lines from `context`'s history, long-polling when
    /// they aren't there yet and `waitSeconds` allows it.
    ///
    /// `waitSeconds < 0` is rejected up front as the pinned corrective
    /// message, before any read. Otherwise every read follows the same rule:
    /// stop and return as soon as the range is non-empty, the command's
    /// status is anything other than `running` (including unknown — no
    /// record ever matches `.running`), or there is no time left on the
    /// deadline (including no `waitSeconds` at all, which never engages the
    /// wait). Only when none of those hold does the loop sleep
    /// `pollInterval` and re-read.
    func execute(in context: ShellContext) async throws -> GetLinesOutput {
        if let waitSeconds, waitSeconds < 0 {
            return .corrective("waitSeconds must be non-negative")
        }

        let clock = ContinuousClock()
        let deadline = waitSeconds.map { clock.now.advanced(by: .seconds($0)) }

        while true {
            let lines = try await context.state.getLines(commandID: commandID, start: start, end: end)
            let status = await Self.status(commandID: commandID, in: context)

            let keepWaiting =
                lines.isEmpty && status == .running && (deadline.map { clock.now < $0 } ?? false)
            guard keepWaiting else {
                return .found(Self.result(commandID: commandID, lines: lines, status: status))
            }

            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// The current status of `commandID` in `context`, or `nil` when no
    /// record matches (unknown id). A thin projection over `listCommands()`
    /// — the same O(small) query `ExecuteCommand.result(for:in:)` uses —
    /// rather than a new `ShellState` method, so the poll cadence above stays
    /// entirely in this op's `execute(in:)` loop.
    private static func status(commandID: Int, in context: ShellContext) async -> CommandStatus? {
        await context.state.listCommands().first { $0.id == commandID }?.status
    }

    /// Assemble the wire `LineRange` for one read: the covered bounds and
    /// formatted lines from `lines`, plus `status`'s raw value — omitted, not
    /// encoded `null`, when `status` is `nil`.
    private static func result(commandID: Int, lines: [LogLine], status: CommandStatus?) -> LineRange {
        LineRange(
            commandID: commandID,
            first: lines.first?.lineNumber ?? 0,
            last: lines.last?.lineNumber ?? 0,
            lines: lines.map { "\($0.lineNumber): \($0.text)" },
            status: status?.rawValue
        )
    }
}

/// The output of `GetLines`: either the requested range (possibly after
/// long-polling), or a corrective message when `waitSeconds` was negative.
///
/// Encoded so the fused tool's `String` output carries either the result
/// object or the bare correction text — the model reads and acts on either.
/// Same shape as `ExecuteOutput`/`KillOutput`.
internal enum GetLinesOutput: Encodable, Sendable, Equatable {
    /// The read resolved (with or without waiting); carries the range.
    case found(LineRange)
    /// `waitSeconds` was negative; carries the corrective message.
    case corrective(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .found(let range):
            try container.encode(range)
        case .corrective(let message):
            try container.encode(message)
        }
    }
}

/// The structured result of `get lines`: the covered line-number range, the
/// line-number-prefixed lines themselves, and the command's current status.
///
/// For an unknown `commandID` (or a range covering no stored lines) the range
/// is empty: `first` and `last` are both `0` and `lines` is empty — parity
/// with the Rust op, which reports no output rather than failing.
internal struct LineRange: Encodable, Sendable, Equatable {
    /// The command whose output these lines came from.
    let commandID: Int
    /// The first covered line number, or `0` when the result is empty.
    let first: Int
    /// The last covered line number, or `0` when the result is empty.
    let last: Int
    /// The retrieved lines, each formatted `"{lineNumber}: {text}"`.
    let lines: [String]
    /// The command's current status raw value (`running`/`completed`/
    /// `killed`/`timed_out`); `nil` (and omitted, not encoded `null`) for an
    /// unknown `commandID`. This is how the model knows whether a poll loop
    /// should keep calling `get lines` again.
    let status: String?

    /// The Swift property `commandID` uses correct acronym casing, but its
    /// encoded JSON key stays `commandId` — the wire contract the model reads
    /// and the JSON-shape acceptance criterion pins. The remaining keys keep
    /// their synthesized names. (Same technique as `ExecuteResult`.)
    enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case first
        case last
        case lines
        case status
    }
}
