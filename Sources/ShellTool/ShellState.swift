// `ShellState` — the per-process history actor and its `.shell/log` store.
//
// State is brief, execution is long: `ShellState` is touched only to record
// bookkeeping (start a command, register its pid, append its captured lines,
// mark it done) and to serve history queries (`getLines`, `grep`). It never
// runs or waits on a child process, so a long-running command can never hold
// the actor. All methods are O(small) apart from the append-only log write and
// the line-by-line log scans in `getLines`/`grep`.
//
// History is per session (per process): every log line is prefixed with this
// process's `sessionID`, and the readers filter by `{sessionID}:{cmdID}:`, so a
// query only ever sees this session's output even when several sessions share
// one `.shell` directory. This is parity with the Rust `swissarmyhammer` shell
// tool's `ShellState`.

import Foundation

/// Execution status of a tracked command.
///
/// The raw values are the on-the-wire strings the Rust tool emits, so responses
/// stay identical across the port.
enum CommandStatus: String, Sendable {
    case running
    case completed
    case killed
    case timedOut = "timed_out"
}

/// Metadata for a single command execution.
struct CommandRecord: Sendable {
    /// Monotonic, 1-based id assigned by `startCommand`.
    let id: Int
    /// The command string as submitted.
    let command: String
    /// Current execution status.
    var status: CommandStatus
    /// Process exit code once known (`nil` while running; `-1` on timeout).
    var exitCode: Int?
    /// Count of log lines recorded for this command (stdout then stderr).
    var lineCount: Int
    /// Monotonic start instant, for durations that ignore wall-clock changes.
    let startedAt: ContinuousClock.Instant
    /// Wall-clock start time, for display.
    let startedAtWall: Date
    /// Monotonic completion instant, set once the command finishes.
    var completedAt: ContinuousClock.Instant?
    /// Wall-clock completion time, set once the command finishes.
    var completedAtWall: Date?

    /// Elapsed time from start to completion, or to now while still running.
    var duration: Duration {
        startedAt.duration(to: completedAt ?? ContinuousClock().now)
    }
}

/// One line retrieved from the log by `getLines`.
struct LogLine: Equatable, Sendable {
    /// The command-scoped 1-based line number.
    let lineNumber: Int
    /// The line text (without the storage prefix or trailing newline).
    let text: String
}

/// One matching line returned by `grep`.
struct GrepResult: Equatable, Sendable {
    /// The command the line belongs to.
    let commandID: Int
    /// The command-scoped 1-based line number.
    let lineNumber: Int
    /// The matching line text.
    let text: String
}

/// The outcome of a `grep`: the (capped) matches plus the full match count.
struct GrepResults: Sendable {
    /// Matches, capped at the requested `limit`.
    let results: [GrepResult]
    /// Total number of matches found, independent of `limit`.
    let total: Int
}

/// Recoverable errors surfaced by `ShellState`.
enum ShellStateError: Error, CustomStringConvertible {
    /// `appendLines`/`killProcess` referenced a command id that was never started.
    case unknownCommand(Int)
    /// `killProcess` referenced a command with no registered running process.
    case noRunningProcess(Int)
    /// `grep` was given a pattern that failed to compile as a regex.
    case invalidRegex(pattern: String, underlying: any Error)
    /// The log file could not be created in the resolved storage directory.
    case logCreationFailed(URL)

    var description: String {
        switch self {
        case .unknownCommand(let id):
            return "Unknown command ID \(id)"
        case .noRunningProcess(let id):
            return "No running process for command ID \(id)"
        case .invalidRegex(let pattern, let underlying):
            return "Invalid regex pattern \"\(pattern)\": \(underlying)"
        case .logCreationFailed(let url):
            return "Failed to create log file at \(url.path)"
        }
    }
}

/// The virtual shell's history and output store — one instance per process.
actor ShellState {
    /// A fresh session identifier, unique to this process.
    nonisolated let sessionID: String
    /// The append-only `.shell/log` file this session reads and writes.
    nonisolated let logURL: URL

    private var commands: [CommandRecord] = []
    /// Running commands only: command id → process-group leader pid.
    private var processes: [Int: pid_t] = [:]

    // MARK: - Initialization

    /// Create a `ShellState`, preferring `preferredDirectory` for the `.shell`
    /// store and falling back to a unique temp directory when it is `nil` or
    /// cannot be created (missing, read-only, or otherwise unwritable).
    ///
    /// The read-only fallback matters for GUI launches: an app opened from
    /// Finder runs with cwd `/`, a read-only system volume, so `<cwd>/.shell`
    /// cannot be created there. Falling back keeps construction from failing.
    init(preferredDirectory: URL?) throws {
        let session = UUID().uuidString
        let directory = try Self.resolveDirectory(preferred: preferredDirectory, sessionID: session)
        self.sessionID = session
        self.logURL = directory.appendingPathComponent("log")
    }

    /// Create a `ShellState` rooted at `<cwd>/.shell`, with the temp fallback.
    init() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        try self.init(preferredDirectory: cwd.appendingPathComponent(".shell"))
    }

    // MARK: - Command lifecycle

    /// Start tracking a new command and return its monotonic 1-based id.
    func startCommand(_ command: String) -> Int {
        let id = commands.count + 1
        commands.append(CommandRecord(
            id: id,
            command: command,
            status: .running,
            exitCode: nil,
            lineCount: 0,
            startedAt: ContinuousClock().now,
            startedAtWall: Date(),
            completedAt: nil,
            completedAtWall: nil
        ))
        return id
    }

    /// Register the running process-group leader pid for a command.
    func registerProcess(commandID: Int, pid: pid_t) {
        processes[commandID] = pid
    }

    /// Append captured output for a command to the log — every `stdout` line
    /// then every `stderr` line, sharing one continuing 1-based per-command
    /// line counter, each stored as `{sessionID}:{cmdID}:{lineNumber}:{text}\n`.
    func appendLines(commandID: Int, stdout: [String] = [], stderr: [String] = []) throws {
        guard let index = commands.firstIndex(where: { $0.id == commandID }) else {
            throw ShellStateError.unknownCommand(commandID)
        }

        var buffer = Data()
        for line in stdout + stderr {
            commands[index].lineCount += 1
            let entry = "\(sessionID):\(commandID):\(commands[index].lineCount):\(line)\n"
            buffer.append(Data(entry.utf8))
        }
        guard !buffer.isEmpty else { return }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: buffer)
    }

    /// Mark a command finished with the given status and exit code, dropping its
    /// running-process entry. A no-op for an unknown id (parity).
    func completeCommand(commandID: Int, status: CommandStatus = .completed, exitCode: Int? = nil) {
        processes[commandID] = nil
        guard let index = commands.firstIndex(where: { $0.id == commandID }) else { return }
        commands[index].status = status
        commands[index].exitCode = exitCode
        commands[index].completedAt = ContinuousClock().now
        commands[index].completedAtWall = Date()
    }

    /// Finalize a command **only if it is still running**, in a single actor
    /// hop. This is the atomic transition the runner uses to record a normal or
    /// timed-out completion: because the check and the write happen without an
    /// intervening suspension, a concurrent `killProcess` that already flipped
    /// the record to `.killed` is never clobbered back. A no-op for an unknown
    /// id or an already-finalized command.
    func completeIfRunning(commandID: Int, status: CommandStatus, exitCode: Int?) {
        guard let index = commands.firstIndex(where: { $0.id == commandID }),
            commands[index].status == .running
        else { return }
        completeCommand(commandID: commandID, status: status, exitCode: exitCode)
    }

    /// Kill a running command by sending `SIGKILL` to its process group, then
    /// mark it killed and return its record. Throws when no process is
    /// registered for the id, so the caller never sends a signal to a stale or
    /// wrong process group.
    @discardableResult
    func killProcess(commandID: Int) throws -> CommandRecord {
        guard let pid = processes[commandID] else {
            throw ShellStateError.noRunningProcess(commandID)
        }
        killpg(pid, SIGKILL)

        // Route the state mutation through `completeCommand`, the single source
        // of truth for command completion (clears the process entry, sets
        // status/exitCode/completed timestamps) — a killed command has no exit
        // code. Re-fetch the index afterwards to return the updated record.
        completeCommand(commandID: commandID, status: .killed, exitCode: nil)
        guard let index = commands.firstIndex(where: { $0.id == commandID }) else {
            throw ShellStateError.unknownCommand(commandID)
        }
        return commands[index]
    }

    /// All command records in start order.
    func listCommands() -> [CommandRecord] {
        commands
    }

    // MARK: - History queries

    /// Read a command's lines from the log, optionally bounded to
    /// `start...end` (defaults: `1` and unbounded). Scans only this session's
    /// lines for `commandID`; an unknown id yields an empty result (parity).
    func getLines(commandID: Int, start: Int? = nil, end: Int? = nil) throws -> [LogLine] {
        let lower = start ?? 1
        let upper = end ?? Int.max
        let prefix = "\(sessionID):\(commandID):"

        var results: [LogLine] = []
        for line in try readLogLines() {
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":"),
                  let number = Int(rest[..<colon]),
                  number >= lower, number <= upper else { continue }
            let text = String(rest[rest.index(after: colon)...])
            results.append(LogLine(lineNumber: number, text: text))
        }
        return results
    }

    /// Search this session's log lines with a regex, optionally scoped to one
    /// `commandID`. `literal: true` pre-escapes the pattern so it matches
    /// verbatim. Matching is line-by-line — one command's binary garbage can't
    /// break another's search — and capped at `limit` (default 10), while
    /// `total` reflects every match found.
    func grep(pattern: String, literal: Bool = false, commandID: Int? = nil, limit: Int? = nil) throws -> GrepResults {
        let cap = limit ?? 10
        let source = literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        let regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(source)
        } catch {
            throw ShellStateError.invalidRegex(pattern: pattern, underlying: error)
        }

        let sessionPrefix = "\(sessionID):"
        var results: [GrepResult] = []
        var total = 0
        for line in try readLogLines() {
            guard ((try? regex.firstMatch(in: line)) ?? nil) != nil else { continue }
            guard let entry = Self.parseLogLine(line, sessionPrefix: sessionPrefix, commandIDFilter: commandID) else { continue }
            total += 1
            if results.count < cap {
                results.append(entry)
            }
        }
        return GrepResults(results: results, total: total)
    }

    // MARK: - Log scanning helpers

    /// Read the log file and split it into lines, delegating the byte-level
    /// split-and-decode to the shared `OutputBuffer.splitLogLines` so this
    /// reader and the writer's `OutputBuffer.logLines` stay in lockstep on
    /// `\n`-byte splitting, lossy UTF-8 decoding, and CRLF handling. This method
    /// keeps only the file-reading wrapper. `Data` is passed straight through
    /// (no full-buffer copy) via the shared function's `Collection<UInt8>`.
    private func readLogLines() throws -> [String] {
        let data = try Data(contentsOf: logURL)
        return OutputBuffer.splitLogLines(data)
    }

    /// Parse one `{sessionID}:{cmdID}:{lineNumber}:{text}` log line into a
    /// `GrepResult`, rejecting lines from another session, lines failing the
    /// optional command-id filter, and lines whose fields don't parse.
    private static func parseLogLine(_ line: String, sessionPrefix: String, commandIDFilter: Int?) -> GrepResult? {
        guard line.hasPrefix(sessionPrefix) else { return nil }
        let rest = line.dropFirst(sessionPrefix.count)
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let commandID = Int(parts[0]) else { return nil }
        if let filter = commandIDFilter, filter != commandID { return nil }
        guard let lineNumber = Int(parts[1]) else { return nil }
        // Mirror Rust `grep`'s `str::trim_end()`: drop trailing whitespace from
        // the matched line's text. (`getLines` deliberately keeps it.)
        var text = parts[2]
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return GrepResult(commandID: commandID, lineNumber: lineNumber, text: String(text))
    }

    // MARK: - Storage directory resolution

    /// The `.shell/.gitignore` body: ignore everything in the directory except
    /// the `.gitignore` itself, so a project's `.shell` store stays untracked.
    private static let gitignoreContent = """
        # Shell runtime data
        # This file is automatically created by FoundationModelsShelltool

        # Ignore everything except this gitignore
        *
        !.gitignore

        """

    /// Resolve and prepare the storage directory: try `preferred`, and on any
    /// failure fall back to `<tmp>/.shell-{sessionID}`.
    private static func resolveDirectory(preferred: URL?, sessionID: String) throws -> URL {
        if let preferred {
            do {
                try prepareDirectory(preferred)
                return preferred
            } catch {
                // Preferred location is unusable (e.g. read-only cwd); fall back.
            }
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent(".shell-\(sessionID)", isDirectory: true)
        try prepareDirectory(fallback)
        return fallback
    }

    /// Create `dir`, seed its `.gitignore` if absent, and touch the `log` file.
    /// Throws if the directory or log cannot be created (the fallback trigger).
    private static func prepareDirectory(_ dir: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let gitignore = dir.appendingPathComponent(".gitignore")
        if !fileManager.fileExists(atPath: gitignore.path) {
            try gitignoreContent.write(to: gitignore, atomically: true, encoding: .utf8)
        }

        let log = dir.appendingPathComponent("log")
        if !fileManager.fileExists(atPath: log.path) {
            guard fileManager.createFile(atPath: log.path, contents: nil) else {
                throw ShellStateError.logCreationFailed(log)
            }
        }
    }
}
