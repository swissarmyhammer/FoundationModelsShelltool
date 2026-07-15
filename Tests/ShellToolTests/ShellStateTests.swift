import Foundation
import Testing

@testable import ShellTool

/// Behavioral tests for `ShellState` and its `.shell/log` store.
///
/// Each test roots a fresh `ShellState` in its own unique temporary directory,
/// so the tests are independent and safe to run in parallel.
@Suite struct ShellStateTests {

    /// Create a fresh, unique temporary directory for a single test.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellstate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `ShellState` rooted at `<tmp>/.shell`.
    private func makeState(in tmp: URL) throws -> ShellState {
        try ShellState(preferredDirectory: tmp.appendingPathComponent(".shell"))
    }

    /// Failure spawning the child used by the `killProcess` round-trip test.
    private enum SpawnError: Error { case attrInit, spawn(Int32) }

    /// Spawn a real, long-lived `/bin/sleep` child in its **own** process group
    /// (so its process-group id equals its pid), mirroring how the executor
    /// launches commands (`process_group(0)`, parity with the Rust reference).
    ///
    /// This is what makes the `killProcess` test a genuine round-trip: the
    /// group-directed `killpg(pid, SIGKILL)` inside `killProcess` targets only
    /// this child, never the test runner's own process group. Returns the
    /// child's pid, which doubles as its process-group id.
    private func spawnKillableChild(seconds: String = "60") throws -> pid_t {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw SpawnError.attrInit }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let path = "/bin/sleep"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup(seconds), nil]
        defer { for case let arg? in argv { free(arg) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attr, argv, environ)
        guard rc == 0 else { throw SpawnError.spawn(rc) }
        return pid
    }

    // MARK: - Storage round-trip

    @Test func storageRoundTripWritesAndReadsBackLines() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id = await state.startCommand("echo hello")
        try await state.appendLines(commandId: id, stdout: ["hello", "world"])

        let lines = try await state.getLines(commandId: id)
        #expect(lines == [LogLine(lineNumber: 1, text: "hello"),
                          LogLine(lineNumber: 2, text: "world")])
    }

    @Test func gitignoreSelfIgnoreWrittenOnFirstUse() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let shellDir = tmp.appendingPathComponent(".shell")
        _ = try ShellState(preferredDirectory: shellDir)

        let gitignore = shellDir.appendingPathComponent(".gitignore")
        #expect(FileManager.default.fileExists(atPath: gitignore.path))
        let content = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(content.contains("*"))
        #expect(content.contains("!.gitignore"))
    }

    // MARK: - Ids and line numbering

    @Test func commandIdsAreMonotonicAndOneBased() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id1 = await state.startCommand("first")
        let id2 = await state.startCommand("second")
        #expect(id1 == 1)
        #expect(id2 == 2)
        let commands = await state.listCommands()
        #expect(commands.count == 2)
    }

    @Test func lineNumbersContinueFromStdoutIntoStderr() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id = await state.startCommand("noisy")
        try await state.appendLines(commandId: id,
                                    stdout: ["out1", "out2"],
                                    stderr: ["err1", "err2"])

        let lines = try await state.getLines(commandId: id)
        #expect(lines == [
            LogLine(lineNumber: 1, text: "out1"),
            LogLine(lineNumber: 2, text: "out2"),
            LogLine(lineNumber: 3, text: "err1"),
            LogLine(lineNumber: 4, text: "err2"),
        ])
        let commands = await state.listCommands()
        #expect(commands[0].lineCount == 4)
    }

    // MARK: - Per-session filtering

    @Test func linesFromAnotherSessionAreInvisible() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let shellDir = tmp.appendingPathComponent(".shell")
        let a = try ShellState(preferredDirectory: shellDir)
        let b = try ShellState(preferredDirectory: shellDir)
        #expect(a.sessionId != b.sessionId)

        let idA = await a.startCommand("a")
        let idB = await b.startCommand("b")
        try await a.appendLines(commandId: idA, stdout: ["shared_word from A"])
        try await b.appendLines(commandId: idB, stdout: ["shared_word from B"])

        // getLines is per-session: each state sees only its own lines.
        let aLines = try await a.getLines(commandId: idA)
        #expect(aLines == [LogLine(lineNumber: 1, text: "shared_word from A")])
        let bLines = try await b.getLines(commandId: idB)
        #expect(bLines == [LogLine(lineNumber: 1, text: "shared_word from B")])

        // grep is per-session too: the pattern matches both lines on disk, but
        // `a` only counts and returns its own.
        let aGrep = try await a.grep(pattern: "shared_word")
        #expect(aGrep.total == 1)
        #expect(aGrep.results.count == 1)
        #expect(aGrep.results.first?.text == "shared_word from A")
    }

    // MARK: - grep

    @Test func grepRespectsLimitAndReportsTotalSeparately() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id = await state.startCommand("many")
        try await state.appendLines(commandId: id, stdout: (1...20).map { "match_\($0)" })

        let result = try await state.grep(pattern: "match_", limit: 5)
        #expect(result.results.count == 5)
        #expect(result.total == 20)
    }

    @Test func grepInvalidRegexSurfacesRecoverableError() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("x")
        try await state.appendLines(commandId: id, stdout: ["text"])

        await #expect(throws: (any Error).self) {
            _ = try await state.grep(pattern: "[unclosed")
        }
    }

    @Test func grepLiteralTreatsPatternAsPlainText() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("literal")
        try await state.appendLines(commandId: id,
                                    stdout: ["a.b matches here", "axb should not match"])

        // As a literal, "a.b" only matches the line containing "a.b".
        let literal = try await state.grep(pattern: "a.b", literal: true)
        #expect(literal.total == 1)
        #expect(literal.results.first?.text == "a.b matches here")

        // As a regex, "a.b" matches both (the dot is a wildcard).
        let regex = try await state.grep(pattern: "a.b")
        #expect(regex.total == 2)
    }

    // MARK: - getLines ranges and unknown ids

    @Test func getLinesDefaultRangeReturnsEverything() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("seq")
        try await state.appendLines(commandId: id, stdout: (1...5).map { "line\($0)" })

        let all = try await state.getLines(commandId: id)
        #expect(all.count == 5)
        #expect(all.first == LogLine(lineNumber: 1, text: "line1"))
        #expect(all.last == LogLine(lineNumber: 5, text: "line5"))
    }

    @Test func getLinesHonorsStartAndEnd() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("seq")
        try await state.appendLines(commandId: id, stdout: (1...10).map { "data\($0)" })

        let mid = try await state.getLines(commandId: id, start: 3, end: 7)
        #expect(mid.map(\.lineNumber) == [3, 4, 5, 6, 7])
        #expect(mid.first?.text == "data3")
        #expect(mid.last?.text == "data7")
    }

    @Test func getLinesUnknownCommandReturnsEmpty() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        _ = await state.startCommand("real")

        let result = try await state.getLines(commandId: 999)
        #expect(result.isEmpty)
    }

    // MARK: - Trailing-whitespace parity with the Rust reference

    /// Rust `grep` builds result text with `str::trim_end()`, so trailing
    /// whitespace on a matched line is dropped. The Swift port must match.
    @Test func grepTrimsTrailingWhitespaceFromResultText() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("trailing")
        try await state.appendLines(commandId: id, stdout: ["match here   "])

        let result = try await state.grep(pattern: "match")
        #expect(result.results.first?.text == "match here")
    }

    /// Rust `get_lines` reads via `BufRead::lines()`, which strips a trailing
    /// `\r` from CRLF output but keeps other trailing whitespace. The Swift
    /// port must match: `\r` gone, spaces preserved.
    @Test func getLinesStripsTrailingCarriageReturnButKeepsSpaces() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("crlf")
        try await state.appendLines(commandId: id, stdout: ["carriage\r", "spaces here  "])

        let lines = try await state.getLines(commandId: id)
        #expect(lines == [LogLine(lineNumber: 1, text: "carriage"),
                          LogLine(lineNumber: 2, text: "spaces here  ")])
    }

    // MARK: - Read-only cwd fallback

    @Test func readOnlyCwdFallsBackToTempDirectory() async throws {
        let tmp = try makeTempDir()
        let readOnly = tmp.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer {
            // Restore perms so cleanup can remove the tree.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let state = try ShellState(preferredDirectory: readOnly.appendingPathComponent(".shell"))
        defer { try? FileManager.default.removeItem(at: state.logURL.deletingLastPathComponent()) }

        // It fell back away from the read-only directory...
        #expect(!state.logURL.path.hasPrefix(readOnly.path))
        // ...and the fallback location is actually usable.
        #expect(FileManager.default.fileExists(atPath: state.logURL.path))
    }

    // MARK: - Process bookkeeping

    @Test func startCommandCreatesRunningRecord() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("ls -la")
        let commands = await state.listCommands()
        #expect(commands.count == 1)
        #expect(commands[0].id == id)
        #expect(commands[0].command == "ls -la")
        #expect(commands[0].status == .running)
        #expect(commands[0].exitCode == nil)
        #expect(commands[0].lineCount == 0)
    }

    @Test func completeCommandSetsStatusAndExitCode() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("echo done")
        await state.completeCommand(commandId: id, exitCode: 0)
        let commands = await state.listCommands()
        #expect(commands[0].status == .completed)
        #expect(commands[0].exitCode == 0)
        #expect(commands[0].completedAt != nil)
    }

    @Test func completeCommandCanMarkTimedOut() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        let id = await state.startCommand("sleep 999")
        await state.completeCommand(commandId: id, status: .timedOut, exitCode: -1)
        let commands = await state.listCommands()
        #expect(commands[0].status == .timedOut)
        #expect(commands[0].exitCode == -1)
        #expect(commands[0].completedAt != nil)
    }

    @Test func killProcessWithoutRunningProcessThrows() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)
        _ = await state.startCommand("noproc")
        await #expect(throws: (any Error).self) {
            _ = try await state.killProcess(commandId: 1)
        }
    }

    /// The `registerProcess` → `killProcess` happy path: a real, running child
    /// is registered, killed, marked `.killed`, and dropped from the running
    /// process map — the round-trip the error-only test above never exercises.
    @Test func registerThenKillProcessKillsChildMarksKilledAndDropsIt() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id = await state.startCommand("sleep 60")
        let pid = try spawnKillableChild()
        await state.registerProcess(commandId: id, pid: pid)

        // The child is genuinely alive before we kill it.
        #expect(kill(pid, 0) == 0)

        let record = try await state.killProcess(commandId: id)
        #expect(record.status == .killed)
        #expect(record.completedAt != nil)

        // The stored record reflects the kill too.
        let commands = await state.listCommands()
        #expect(commands[0].status == .killed)
        #expect(commands[0].completedAt != nil)

        // The running-process entry was dropped: a second kill finds nothing to
        // signal and surfaces the no-running-process error.
        await #expect(throws: (any Error).self) {
            _ = try await state.killProcess(commandId: id)
        }

        // Genuine round-trip: reap the child (blocks until it exits — no timing
        // races) and confirm SIGKILL actually terminated it.
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, 0)
        #expect(reaped == pid)
        #expect((status & 0x7f) == SIGKILL)
    }

    // MARK: - Atomic completion transition

    /// `completeIfRunning` finalizes a still-running command in one actor hop.
    @Test func completeIfRunningTransitionsARunningCommand() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id = await state.startCommand("echo hi")
        await state.completeIfRunning(commandId: id, status: .completed, exitCode: 0)

        let commands = await state.listCommands()
        #expect(commands[0].status == .completed)
        #expect(commands[0].exitCode == 0)
        #expect(commands[0].completedAt != nil)
    }

    /// `completeIfRunning` must NOT clobber a command already finalized by another
    /// path (e.g. an external `killProcess` marking it `.killed`) — the guarantee
    /// the runner relies on, made atomic so a concurrent kill can't slip through a
    /// check-then-act gap.
    @Test func completeIfRunningLeavesAnAlreadyKilledCommandUntouched() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = try makeState(in: tmp)

        let id = await state.startCommand("sleep 60")
        let pid = try spawnKillableChild()
        await state.registerProcess(commandId: id, pid: pid)
        _ = try await state.killProcess(commandId: id)  // marks .killed

        // The runner's post-run completion must be a no-op now.
        await state.completeIfRunning(commandId: id, status: .completed, exitCode: 0)

        let commands = await state.listCommands()
        #expect(commands[0].status == .killed)
        #expect(commands[0].exitCode == nil)

        // Clean up the killed child (already SIGKILLed by killProcess).
        var reapStatus: Int32 = 0
        _ = waitpid(pid, &reapStatus, 0)
    }
}
