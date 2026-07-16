// `GrepHistory` — the `grep history` operation.
//
// A direct behavioral port of the Rust `swissarmyhammer-tools`
// `shell/grep_history`. It searches this session's recorded command output —
// via `ShellState.grep`, which scans the `.shell/log` line by line, optionally
// escaping the pattern for a literal match and optionally scoping to one
// command — and returns the (capped) matches alongside the full match count.
//
// An invalid regex pattern is an EXPECTED failure the model should recover
// from within the turn — it can rephrase the pattern — so it is **returned**
// as a corrective message rather than thrown: `OperationTool` surfaces a thrown
// `execute(in:)` as a fatal error that aborts the turn, but returns the
// operation's output to the model. Carrying the correction in the output
// (`GrepOutput.corrective`) therefore matches the framework's "return, don't
// throw" design, exactly as `ExecuteCommand` and `KillProcess` do.
//
// The `total`/`shown` split is the point of the op: `limit` caps how many
// matches come back (default `10`), but `total` always reports every match, so
// the model knows to raise `limit` when it has been truncated. This is the plan
// §8.3 default; the Rust doc string's stale "50" is not carried over.

import FoundationModels
import Foundation
import Operations

/// Searches this session's command-output history for a regex (or, with
/// `literal`, an exact-text) pattern, optionally scoped to one command.
@Generable
@Operation(
    verb: "grep",
    noun: "history",
    description: "Regex pattern match across command output history. Exact structural search."
)
internal struct GrepHistory {
    @Guide(
        description:
            "Regex pattern to match against command output. When literal is true, matched as exact text (no escaping needed)."
    )
    @OperationParam(short: "p")
    var pattern: String

    @Guide(
        description:
            "Treat pattern as literal text instead of regex (default: false). Use this to avoid backslash escaping issues."
    )
    @OperationParam(short: "l")
    var literal: Bool?

    @Guide(description: "Filter to a specific command's output (optional)")
    @OperationParam(short: "i")
    var commandID: Int?

    @Guide(description: "Maximum number of results (default: 10)")
    @OperationParam(short: "n")
    var limit: Int?
}

extension GrepHistory {
    /// Run the grep against `context`'s history and format the outcome.
    ///
    /// Delegates the scan to `ShellState.grep`, which owns the regex
    /// compilation, optional literal-escaping, per-command filtering, and the
    /// `limit` cap. A pattern that fails to compile short-circuits to a
    /// corrective message instead of throwing, so the model can rephrase within
    /// the turn.
    func execute(in context: ShellContext) async throws -> GrepOutput {
        do {
            let found = try await context.state.grep(
                pattern: pattern,
                literal: literal ?? false,
                commandID: commandID,
                limit: limit
            )
            let matches = found.results.map {
                GrepMatch(commandID: $0.commandID, lineNumber: $0.lineNumber, text: $0.text)
            }
            return .matches(
                GrepMatches(matches: matches, shown: matches.count, total: found.total))
        } catch ShellStateError.invalidRegex(let pattern, let underlyingMessage) {
            // An uncompilable pattern: return the correction rather than throw,
            // so the model can rephrase within the turn.
            return .corrective(
                ShellStateError.invalidRegex(pattern: pattern, underlyingMessage: underlyingMessage)
                    .description)
        }
    }
}

/// The output of `GrepHistory`: either the structured matches, or a corrective
/// message when the pattern failed to compile as a regex.
///
/// Encoded so the fused tool's `String` output carries either the result
/// object or the bare correction text — the model reads and acts on either.
/// Same shape as `ExecuteOutput` and `KillOutput`.
internal enum GrepOutput: Encodable, Sendable, Equatable {
    /// The pattern compiled and the search ran; carries the matches and counts.
    case matches(GrepMatches)
    /// The pattern failed to compile; carries the corrective message.
    case corrective(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .matches(let result):
            try container.encode(result)
        case .corrective(let message):
            try container.encode(message)
        }
    }
}

/// The structured result of a `grep history` search: the (capped) matching
/// lines plus how many were shown and how many matched in total.
///
/// `shown` equals `matches.count`; `total` is independent of `limit`, so a
/// `total` greater than `shown` tells the model its results were truncated and
/// it can raise `limit` to see more.
internal struct GrepMatches: Encodable, Sendable, Equatable {
    /// The matching lines, capped at the requested `limit`.
    let matches: [GrepMatch]
    /// How many matches are carried in `matches` (`matches.count`).
    let shown: Int
    /// Total number of matches found, independent of `limit`.
    let total: Int
}

/// One matching line from `grep history`: the command it came from, its
/// command-scoped 1-based line number, and the matching text.
internal struct GrepMatch: Encodable, Sendable, Equatable {
    /// The command the matching line belongs to.
    let commandID: Int
    /// The command-scoped 1-based line number.
    let lineNumber: Int
    /// The matching line text (trailing whitespace trimmed, as `grep` stores).
    let text: String

    /// The Swift property `commandID` uses correct acronym casing, but its
    /// encoded JSON key stays `commandId` — the wire contract the model reads
    /// and the JSON-shape acceptance criterion pins. The remaining keys keep
    /// their synthesized names. (Same technique as `ExecuteResult`.)
    enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case lineNumber
        case text
    }
}
