import FoundationModels
import Foundation
import Operations
import Testing

@testable import ShellTool

/// Exercises the `list processes` and `kill process` operations through the
/// model-facing dispatch path — `OperationTool.call` → `AnyOperation` →
/// `execute(in:)` — against a real `ShellContext` that spawns real
/// subprocesses.
///
/// The anchor is the §7.3 concurrency test: `list processes` and `kill
/// process` must answer correctly while a separate `execute command` is still
/// in flight, because `ShellState` is an actor that is never held during a
/// running command.
@Suite struct ProcessOpsTests {

    // MARK: - Tool construction

    /// Build a fresh tool over a `ShellContext` rooted at a unique temp `.shell`
    /// store, with a builtin-only policy (no `~/.shell` or project overlay), so
    /// every test is isolated and deterministic. All three process-related ops
    /// are fused over one shared context, so `list`/`kill` observe the same
    /// `ShellState` a concurrent `execute command` records into.
    private func makeTool() throws -> OperationTool<ShellContext> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        let context = ShellContext(state: state, policy: policy)
        return try OperationTool(
            name: "shell",
            description: "Run shell commands.",
            context: context,
            operations: [
                AnyOperation(ExecuteCommand.self),
                AnyOperation(ListProcesses.self),
                AnyOperation(KillProcess.self),
            ]
        )
    }

    // MARK: - list processes

    @Test func listProcessesDispatchesTheFullHistoryTableForMultipleCommands() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo alpha"]))
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo bravo"]))

        let listed = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))

        // A bare top-level array of rows, one per recorded command.
        #expect(listed.hasPrefix("["))
        #expect(listed.contains("\"id\":1"))
        #expect(listed.contains("\"id\":2"))
        #expect(listed.contains("echo alpha"))
        #expect(listed.contains("echo bravo"))
        #expect(listed.contains("\"status\":\"completed\""))
        #expect(listed.contains("\"exitCode\":0"))
        #expect(listed.contains("\"lineCount\":1"))
    }

    // MARK: - kill process

    @Test func killProcessStopsARunningCommandAndFlipsTheRecordToKilled() async throws {
        let tool = try makeTool()
        let pattern = Self.uniqueSleep()
        // Emit a line, THEN block. Output is now recorded incrementally as it
        // streams in, so the emitted line is already flushed to `ShellState`
        // well before the sleep — this exercises the mid-stream-capture rule
        // rather than trivially counting nothing.
        let command = "echo captured-line; \(pattern)"
        let running = Task {
            try await tool.call(
                arguments: GeneratedContent(properties: ["op": "execute command", "command": command]))
        }
        defer {
            running.cancel()
            Self.killTree(pattern)
        }

        #expect(try await waitUntil { Self.pgrepCount(pattern) > 0 })

        // Wait for the incremental flush to actually land before killing, so
        // the assertion below isn't racing the flush.
        #expect(
            try await waitUntil {
                let listed = try await tool.call(
                    arguments: GeneratedContent(properties: ["op": "list processes"]))
                return listed.contains("\"lineCount\":1")
            })

        let (response, _) = try await killPromptly(tool, id: 1)
        #expect(response.contains("\"id\":1"))
        #expect(response.contains("\"command\":\"\(command)\""))
        // The emitted line was already flushed incrementally before the kill.
        #expect(response.contains("\"linesCaptured\":1"))

        // The record must now read `killed`.
        let listed = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(listed.contains("\"status\":\"killed\""))

        // Drain the background task. Cancel first so that even on a regression
        // where the op-kill failed to kill, cancellation's group-kill unblocks
        // it — the drain never waits out the full sleep.
        running.cancel()
        _ = try? await running.value

        // The line count is unchanged after the kill — the sleep after the
        // echo never emitted anything more to flush.
        let afterDrain = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(afterDrain.contains("\"lineCount\":1"))
    }

    @Test func killProcessOnAnUnknownIdReturnsACorrectiveMessageNotAThrow() async throws {
        let tool = try makeTool()

        // No command was ever started, so id 999 has no running process. This
        // must come back as a corrective string, not throw out of `call`.
        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "kill process", "id": 999]))

        #expect(response.contains("No running process"))
        #expect(response.contains("999"))
        // A corrective message, not a structured kill result.
        #expect(!response.contains("linesCaptured"))
    }

    @Test func killProcessOnAnAlreadyFinishedIdReturnsACorrectiveMessage() async throws {
        let tool = try makeTool()
        // Run a command to completion; its process entry is then cleared.
        _ = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo done"]))

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "kill process", "id": 1]))

        #expect(response.contains("No running process"))
        #expect(!response.contains("linesCaptured"))
    }

    /// A `kill process` payload with NO `id` key comes back as a framework-level
    /// "missing required" correction that names the missing `id` parameter — a
    /// returned string, not a thrown error and not a crash. The resolver
    /// short-circuits before `execute(in:)` runs, so no process is touched.
    @Test func killProcessWithNoIdKeyReturnsACorrectiveNamingTheMissingParameter() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "kill process"]))

        #expect(response.contains("Missing required"))
        #expect(response.contains("id"))
        // A corrective message, not a structured kill result.
        #expect(!response.contains("linesCaptured"))
    }

    // MARK: - §7.3 concurrency: list/kill while a command is still running

    @Test func listAndKillRespondWhileAnExecuteCommandIsStillInFlight() async throws {
        let tool = try makeTool()
        let command = Self.uniqueSleep()

        // Start a long sleep WITHOUT awaiting completion — the `execute
        // command` call blocks until the child dies, so it stays pending in
        // this detached task until we kill it.
        let running = Task {
            try await tool.call(
                arguments: GeneratedContent(properties: ["op": "execute command", "command": command]))
        }
        defer {
            running.cancel()
            Self.killTree(command)
        }

        // Wait until the child process tree is actually up.
        #expect(try await waitUntil { Self.pgrepCount(command) > 0 }, "the sleep child should be running")

        // `list processes` must show it running, with a `+`-style live duration,
        // while the command is still in flight.
        let listed = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(listed.contains("\"status\":\"running\""))
        #expect(listed.contains("s+"))
        #expect(listed.contains(command))

        // `kill process` must return promptly — well under the sleep duration —
        // proving the actor was never held by the running command.
        let (response, elapsed) = try await killPromptly(tool, id: 1)
        #expect(elapsed < .seconds(5), "kill must return promptly, not block on the sleep")
        #expect(response.contains("\"linesCaptured\""), "kill should succeed with a structured result")

        // The record flips to killed.
        let after = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))
        #expect(after.contains("\"status\":\"killed\""))

        // The whole process tree is gone.
        #expect(
            try await waitUntil(.seconds(5)) { Self.pgrepCount(command) == 0 },
            "the killed process tree should be gone")

        // Drain the background task. Cancel first so that even on a regression
        // where the op-kill failed to kill, cancellation's group-kill unblocks
        // it — the drain never waits out the full sleep.
        running.cancel()
        _ = try? await running.value
    }

    // MARK: - JSON-shape snapshots

    @Test func listProcessesResultEncodesTheExpectedFieldNamesAsABareArray() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let result = ListProcessesResult(processes: [
            ProcessRow(
                id: 1, status: "completed", exitCode: 0, lineCount: 3,
                startedAt: "2026-07-15T21:30:00Z", duration: "1.5s", command: "echo hi"),
            ProcessRow(
                id: 2, status: "running", exitCode: nil, lineCount: 0,
                startedAt: "2026-07-15T21:31:00Z", duration: "0.5s+", command: "sleep 300"),
        ])
        let json = try #require(String(data: try encoder.encode(result), encoding: .utf8))

        // A bare top-level array, not an object wrapping the rows.
        #expect(json.hasPrefix("["))
        #expect(json.contains("\"id\":1"))
        #expect(json.contains("\"status\":\"completed\""))
        #expect(json.contains("\"exitCode\":0"))
        #expect(json.contains("\"lineCount\":3"))
        #expect(json.contains("\"startedAt\":\"2026-07-15T21:30:00Z\""))
        #expect(json.contains("\"duration\":\"1.5s\""))
        #expect(json.contains("\"command\":\"echo hi\""))
        // The running row carries the `+`-style live duration.
        #expect(json.contains("\"duration\":\"0.5s+\""))
        #expect(json.contains("\"id\":2"))

        // A nil `exitCode` is omitted entirely (synthesized `encodeIfPresent`).
        let runningOnly = ListProcessesResult(processes: [
            ProcessRow(
                id: 2, status: "running", exitCode: nil, lineCount: 0,
                startedAt: "2026-07-15T21:31:00Z", duration: "0.5s+", command: "sleep 300")
        ])
        let bare = try #require(String(data: try encoder.encode(runningOnly), encoding: .utf8))
        #expect(!bare.contains("exitCode"))
    }

    @Test func killResultEncodesTheExpectedFieldNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let result = KillResult(id: 2, command: "sleep 300", linesCaptured: 4)
        let json = try #require(String(data: try encoder.encode(result), encoding: .utf8))

        #expect(json.contains("\"id\":2"))
        #expect(json.contains("\"command\":\"sleep 300\""))
        #expect(json.contains("\"linesCaptured\":4"))
    }

    // MARK: - Helpers

    /// A `sleep` command with a unique fractional duration, long enough never
    /// to finish during a test. The unique suffix lets `pgrep`/`pkill -f` match
    /// exactly this command's process tree even when tests run in parallel.
    private static func uniqueSleep() -> String {
        "sleep 300.\(Int.random(in: 100_000..<1_000_000))"
    }

    /// Count the live processes whose full command line matches `pattern`,
    /// via `pgrep -f`. Spawned DIRECTLY (not through `sh -c`), so the only
    /// process carrying `pattern` besides the target tree is `pgrep` itself —
    /// which `pgrep` excludes — avoiding a self-match false positive.
    private static func pgrepCount(_ pattern: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
    }

    /// Best-effort teardown net: SIGKILL any process tree still matching
    /// `pattern`, so a failed test can never leak a `sleep` child.
    private static func killTree(_ pattern: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", pattern]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Call `kill process` for `id`, returning the response and how long the
    /// call took. Tolerates the brief window between a command showing
    /// `running` and its pid being registered (a `No running process`
    /// corrective) by retrying for up to five seconds; the measured elapsed
    /// time still proves the kill did not block on the command's own duration.
    private func killPromptly(
        _ tool: OperationTool<ShellContext>, id: Int
    ) async throws -> (response: String, elapsed: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(5))
        var response = ""
        repeat {
            response = try await tool.call(
                arguments: GeneratedContent(properties: ["op": "kill process", "id": id]))
            if !response.contains("No running process") { break }
            try? await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        return (response, start.duration(to: clock.now))
    }

    /// Poll `condition` every 25 ms until it holds or `timeout` elapses,
    /// returning whether it ultimately held.
    @discardableResult
    private func waitUntil(
        _ timeout: Duration = .seconds(10), _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return try await condition()
    }
}
