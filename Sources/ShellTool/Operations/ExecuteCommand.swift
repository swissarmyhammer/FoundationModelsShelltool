// `ExecuteCommand` — the `execute command` operation.
//
// A direct behavioral port of the Rust `swissarmyhammer-tools`
// `shell/execute_command`. It runs one shell command through `ShellContext`:
// validate with `ShellPolicy`, spawn and supervise via `ShellRunner`, record
// output in `ShellState`, then format the tail of the stored output back into a
// structured `ExecuteResult`.
//
// A rejected command (blocked by policy, an unparseable `environment` string,
// or an invalid environment/working directory) is **returned** as a corrective
// message rather than thrown: `OperationTool` rethrows an operation's thrown
// error as fatal, aborting the turn, but returns the operation's output to the
// model. Carrying the correction in the output (`ExecuteOutput.corrective`)
// therefore lets the model rephrase within the same turn — matching the
// `ShellPolicy` contract and the framework's "return, don't throw" design.
//
// `waitSeconds` exposes `ShellRunner.run(_:wait:)`'s soft deadline: this call
// waits up to `waitSeconds` seconds (`defaultWaitSeconds` when omitted, `0` to
// detach immediately) for the command to finish, and returns whichever comes
// first. A command still running once the deadline elapses is reported with
// `status: "running"`, the output captured so far as its tail, `exitCode`
// omitted (the process hasn't exited), and an `outputNote` naming the
// follow-up protocol — `get lines` to keep reading, `kill process` to stop
// it, `list processes` to check on it — rather than the tail-truncation note
// a finished command's `outputNote` carries. This bounds the *call*; `timeout`
// keeps bounding the *child* regardless of whether anyone is still awaiting
// it (see `ShellRunner.run`'s file header).
//
// A negative `waitSeconds` is the one corrective path this adds (mirroring
// `GetLines`'s identical `waitSeconds` convention — see that op's file
// header): checked up front, before any read or spawn.

import FoundationModels
import Foundation
import Operations

/// Executes a shell command with an optional timeout, working directory, and
/// extra environment, under `ShellPolicy` validation.
@Generable
@Operation(
    verb: "execute",
    noun: "command",
    description: "Execute a shell command with timeout and environment control"
)
internal struct ExecuteCommand {
    /// Number of trailing stored lines echoed back in the default response, so
    /// the common "run a command, read its tail" case is a single round-trip.
    /// Larger output is truncated to this tail; the full output stays available
    /// via `get lines`. Parity with the Rust `DEFAULT_TAIL_LINES`.
    static let tailLineCount = 32

    /// Seconds `execute(in:)` waits for the command when `waitSeconds` is
    /// omitted — long enough that a normal command still returns its result
    /// in the same call, short enough that a runaway command still returns
    /// to the model (as a `running` snapshot) within one turn instead of
    /// stalling it indefinitely.
    static let defaultWaitSeconds = 30

    @Guide(description: "The shell command to execute")
    @OperationParam(short: "c")
    var command: String

    @Guide(description: "Seconds before killing the command (optional, default: none)")
    @OperationParam(short: "t")
    var timeout: Int?

    @Guide(description: "Working directory for command execution (optional, defaults to current directory)")
    @OperationParam(short: "w")
    var workingDirectory: String?

    @Guide(
        description:
            "Additional environment variables as a JSON string (optional, e.g. '{\"KEY1\":\"value1\",\"KEY2\":\"value2\"}')"
    )
    @OperationParam(short: "e")
    var environment: String?

    /// No `@OperationParam(short:)`: pinned so this op and `get lines`'s
    /// identically named `waitSeconds` can never diverge into different
    /// short flags (see this file's header and `GetLines`'s).
    @Guide(
        description:
            "Seconds to wait for completion before returning with the command still running (optional, default: 30; 0 returns immediately)"
    )
    var waitSeconds: Int?
}

extension ExecuteCommand {
    /// Validate, run, and format one command against `context`.
    ///
    /// Validation mirrors the Rust pipeline's order — command, then working
    /// directory, then the environment (parse, then policy) — and any failure
    /// short-circuits to a corrective message. On success the command is run to
    /// completion and its stored output tail is formatted into an
    /// `ExecuteResult`.
    func execute(in context: ShellContext) async throws -> ExecuteOutput {
        // Checked first, before any read or spawn — mirroring `GetLines`'s
        // identical `waitSeconds` convention (see that op's file header).
        if let waitSeconds, waitSeconds < 0 {
            return .corrective("waitSeconds must be non-negative")
        }

        // A blank command is rejected before the policy check, mirroring the
        // Rust pipeline's leading `validate_not_empty(command)`.
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .corrective("Shell command cannot be empty")
        }

        if let message = context.policy.check(command: command) {
            return .corrective(message)
        }

        if let workingDirectory, let message = context.policy.check(workingDirectory: workingDirectory) {
            return .corrective(message)
        }

        let parsedEnvironment: [String: String]
        switch Self.parseEnvironment(environment) {
        case .parsed(let environment):
            parsedEnvironment = environment
        case .invalid(let message):
            return .corrective(message)
        }
        if !parsedEnvironment.isEmpty, let message = context.policy.check(environment: parsedEnvironment) {
            return .corrective(message)
        }

        let request = ShellRunner.Request(
            command: command,
            workingDirectory: workingDirectory,
            environment: parsedEnvironment,
            timeout: timeout.map { .seconds($0) }
        )
        switch try await context.runner.run(request, wait: Self.waitDuration(for: waitSeconds)) {
        case .finished(let outcome):
            return .ran(await Self.result(for: outcome, in: context))
        case .running(let commandID):
            return .ran(await Self.runningResult(commandID: commandID, in: context))
        }
    }

    /// The soft deadline `execute(in:)` passes to `ShellRunner.run(_:wait:)`:
    /// `waitSeconds` seconds, or `defaultWaitSeconds` when `waitSeconds` is
    /// `nil`. A pure function (rather than inlined into `execute(in:)`) so
    /// the omitted-`waitSeconds` default is pinned by a direct unit test
    /// against the named constant, without ever waiting out a real 30
    /// seconds.
    static func waitDuration(for waitSeconds: Int?) -> Duration {
        .seconds(waitSeconds ?? defaultWaitSeconds)
    }

    /// Assemble the `ExecuteResult` for a finished command: read its stored
    /// lines back (the same store `get lines` serves), format the trailing
    /// `tailLineCount` as `"{lineNumber}: {text}"`, and attach the tail note
    /// only when the full output exceeds the tail.
    ///
    /// Status and duration are read from the finalized `ShellState` record —
    /// the authoritative source — rather than the runner's `outcome`: a
    /// concurrent `kill process` that flipped the record to `.killed` (which
    /// `completeIfRunning` preserves) is then reported faithfully, instead of
    /// the `.completed` the runner would otherwise return. Exit code prefers
    /// the record but falls back to `outcome.exitCode` for a killed record,
    /// whose stored code is `nil` — yielding `-1`, since the SIGKILL'd child
    /// terminated via a signal. The `outcome` also backstops the impossible
    /// case of a missing record.
    private static func result(
        for outcome: ShellRunner.Outcome, in context: ShellContext
    ) async -> ExecuteResult {
        let record = await context.state.listCommands().first { $0.id == outcome.commandID }
        let stored = (try? await context.state.getLines(commandID: outcome.commandID)) ?? []
        let total = stored.count
        let output = stored.suffix(tailLineCount).map { "\($0.lineNumber): \($0.text)" }
        let note =
            total > tailLineCount
            ? "showing last \(tailLineCount) of \(total) lines — use get lines to retrieve the full output"
            : nil

        return ExecuteResult(
            commandID: outcome.commandID,
            status: (record?.status ?? outcome.status).rawValue,
            exitCode: record?.exitCode ?? outcome.exitCode,
            lines: total,
            durationMs: record.map(durationMs) ?? 0,
            output: output,
            outputNote: note
        )
    }

    /// The fixed advisory `runningResult(commandID:in:)` attaches: the
    /// follow-up protocol for a command still running once `waitSeconds`'s
    /// deadline elapsed, rather than a tail-truncation note.
    static let runningOutputNote =
        "still running — use get lines (with waitSeconds to wait for more output), kill process to stop, list processes to check status"

    /// Assemble the `ExecuteResult` for a command still running once
    /// `waitSeconds`'s soft deadline elapsed: the stored lines captured so
    /// far as the tail (the same window `result(for:in:)` uses), but
    /// `status: "running"`, `exitCode` omitted (the process hasn't exited),
    /// and `outputNote` replaced by `runningOutputNote` rather than a
    /// tail-truncation note.
    ///
    /// `durationMs` comes from the record's `duration`, which — for a
    /// running command — measures elapsed time to *now* rather than to a
    /// completion instant (see `CommandRecord.duration`), so it reports
    /// elapsed-so-far exactly as a `running` snapshot should.
    private static func runningResult(commandID: Int, in context: ShellContext) async -> ExecuteResult {
        let record = await context.state.listCommands().first { $0.id == commandID }
        let stored = (try? await context.state.getLines(commandID: commandID)) ?? []
        let output = stored.suffix(tailLineCount).map { "\($0.lineNumber): \($0.text)" }

        return ExecuteResult(
            commandID: commandID,
            status: CommandStatus.running.rawValue,
            exitCode: nil,
            lines: stored.count,
            durationMs: record.map(durationMs) ?? 0,
            output: output,
            outputNote: runningOutputNote
        )
    }

    /// A command's elapsed run time in whole milliseconds, from its record's
    /// `Duration` (seconds plus attoseconds; `1e15` attoseconds per ms).
    private static func durationMs(_ record: CommandRecord) -> Int {
        let (seconds, attoseconds) = record.duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    /// Parse the `environment` JSON string into a `[String: String]` map.
    ///
    /// A `nil` or empty string yields an empty map (no extra environment). A
    /// string that is not a JSON object of string values yields a corrective
    /// message, matching the Rust "Invalid JSON format for environment
    /// variables" failure.
    static func parseEnvironment(_ json: String?) -> EnvironmentParse {
        guard let json, !json.isEmpty else { return .parsed([:]) }
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return .invalid(
                "Invalid JSON format for environment variables: expected a JSON object mapping string keys to string values"
            )
        }
        var environment: [String: String] = [:]
        for (key, value) in dictionary {
            guard let value = value as? String else {
                return .invalid(
                    "Invalid JSON format for environment variables: value for \(key) is not a string"
                )
            }
            environment[key] = value
        }
        return .parsed(environment)
    }

    /// The outcome of parsing the `environment` JSON string: the parsed map, or
    /// a corrective message when the string is not a JSON object of strings.
    enum EnvironmentParse: Sendable, Equatable {
        case parsed([String: String])
        case invalid(String)
    }
}

/// The output of `ExecuteCommand`: either the structured result of a completed
/// run, or a corrective message when the command was rejected before running.
///
/// Encoded so the fused tool's `String` output carries either the result object
/// or the bare correction text — the model reads and acts on either.
internal enum ExecuteOutput: Encodable, Sendable, Equatable {
    /// The command passed validation and ran; carries its structured result.
    case ran(ExecuteResult)
    /// The command was rejected before running; carries the corrective message.
    case corrective(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ran(let result):
            try container.encode(result)
        case .corrective(let message):
            try container.encode(message)
        }
    }
}

/// The structured result of `execute command`: either a completed run, or a
/// snapshot of a command still `running` once `waitSeconds`'s soft deadline
/// elapsed.
///
/// `exitCode` and `outputNote` are optional and omitted from the encoded
/// JSON when `nil` (the synthesized `Encodable` uses `encodeIfPresent` for
/// optionals — the same technique `ProcessRow.exitCode` uses): `exitCode`
/// appears only once the command has exited; `outputNote` appears only when
/// the stored output was truncated to the tail, or the command is still
/// `running` (carrying the long-poll protocol instead).
internal struct ExecuteResult: Encodable, Sendable, Equatable {
    /// The command's `ShellState`-assigned 1-based id, for later `get lines`.
    let commandID: Int
    /// Current status: `completed`, `timed_out`, `killed`, or `running`.
    let status: String
    /// Process exit code once known; `-1` for a timeout or signal death;
    /// `nil` (and omitted) while the command is still `running`.
    let exitCode: Int?
    /// Total number of stored output lines (stdout then stderr).
    let lines: Int
    /// Elapsed run time in whole milliseconds.
    let durationMs: Int
    /// The trailing stored lines, each formatted `"{lineNumber}: {text}"`.
    let output: [String]
    /// A note carrying the "showing last N of M" tail advisory, present only
    /// when the full output exceeded the tail; `nil` (and omitted) otherwise.
    let outputNote: String?

    /// The Swift property `commandID` uses correct acronym casing, but its
    /// encoded JSON key stays `commandId` — the wire contract the model reads
    /// and the JSON-shape acceptance criterion pins. The remaining keys are
    /// declared explicitly so they keep their current synthesized names.
    /// (Same technique as `ShellSettings.isValidationEnabled = "enable_validation"`.)
    enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case status
        case exitCode
        case lines
        case durationMs
        case output
        case outputNote
    }
}
