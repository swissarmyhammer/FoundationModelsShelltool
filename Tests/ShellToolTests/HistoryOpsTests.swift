import FoundationModels
import Foundation
import Operations
import Testing

@testable import ShellTool

/// Exercises the `grep history` and `get lines` operations through the
/// model-facing dispatch path — `OperationTool.call` → `AnyOperation` →
/// `execute(in:)` — against a real `ShellContext` that spawns real
/// subprocesses and records their output into `ShellState`.
///
/// The anchors are the `limit`/`total` split (a capped `grep` still reports
/// every match) and the invalid-regex correction (a bad pattern comes back as
/// a corrective string, not a thrown fatal error), per the task's TDD note.
@Suite struct HistoryOpsTests {

    /// Build a fresh `ShellContext` rooted at a unique temp `.shell` store, with
    /// a builtin-only policy (no `~/.shell` or project overlay), so every test is
    /// isolated and deterministic.
    private func makeContext() throws -> ShellContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        return ShellContext(state: state, policy: policy)
    }

    /// Build a fresh tool over a `ShellContext` rooted at a unique temp `.shell`
    /// store, with a builtin-only policy (no `~/.shell` or project overlay), so
    /// every test is isolated and deterministic. `execute command` is fused in
    /// alongside the two history ops so a test can produce output and then
    /// grep / get-lines the same `ShellState`.
    private func makeTool() throws -> OperationTool<ShellContext> {
        return try OperationTool(
            name: "shell",
            description: "Run shell commands.",
            context: try makeContext(),
            operations: [
                AnyOperation(ExecuteCommand.self),
                AnyOperation(GrepHistory.self),
                AnyOperation(GetLines.self),
            ]
        )
    }

    // MARK: - grep history: limit / total split

    @Test func grepHistoryRespectsLimitButReportsTotalIndependently() async throws {
        let tool = try makeTool()
        // Five matching output lines from one command.
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command",
                "command": "printf 'MARK\\nMARK\\nMARK\\nMARK\\nMARK\\n'",
            ]))

        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "grep history", "pattern": "MARK", "limit": 2,
            ]))

        // Only `limit` matches are shown, but `total` counts every match.
        #expect(response.contains("\"shown\":2"))
        #expect(response.contains("\"total\":5"))
        #expect(response.contains("\"text\":\"MARK\""))
    }

    // MARK: - grep history: sees a still-running command's incrementally recorded output

    /// `grep history` must see output recorded incrementally while the
    /// producing command is still running, not just after it exits — the
    /// other half of the batch-at-exit supersede (DESIGN_NOTES §8) alongside
    /// `get lines`.
    @Test func grepHistorySeesARunningCommandsOutputBeforeItFinishes() async throws {
        let tool = try makeTool()

        let running = Task {
            try await tool.call(
                arguments: GeneratedContent(properties: [
                    "op": "execute command", "command": "echo MARK; sleep 5",
                ]))
        }
        defer { running.cancel() }

        // Poll `grep history` until the still-running command's output shows up.
        var response = ""
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        repeat {
            response = try await tool.call(
                arguments: GeneratedContent(properties: [
                    "op": "grep history", "pattern": "MARK",
                ]))
            if !response.contains("\"total\":1") { try? await Task.sleep(for: .milliseconds(25)) }
        } while !response.contains("\"total\":1") && clock.now < deadline

        #expect(response.contains("\"total\":1"))
        #expect(response.contains("MARK"))

        running.cancel()
        _ = try? await running.value
    }

    // MARK: - grep history: invalid regex → corrective, not a throw

    @Test func grepHistoryWithInvalidRegexReturnsCorrectiveMessageNotAThrow() async throws {
        let tool = try makeTool()

        // An unbalanced bracket class is not a valid regex. This must come back
        // as a corrective string, not throw out of `call`.
        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "grep history", "pattern": "[invalid",
            ]))

        #expect(response.contains("Invalid regex"))
        // A corrective message, not a structured match result.
        #expect(!response.contains("\"total\""))
        #expect(!response.contains("\"shown\""))
    }

    /// Drives `GrepHistory.execute(in:)` directly — the op's own execute path,
    /// against a real `ShellContext`/`ShellState` — with a syntactically invalid
    /// regex. This closes the round-trip the `tool.call` test only sees through
    /// the encoded string: the producer (`ShellState.grep`) throws
    /// `ShellStateError.invalidRegex`, and the consuming catch must reshape it
    /// into a `.corrective` `GrepOutput` rather than let the throw escape. The
    /// assertion is on the returned enum case and its message text, so it fails
    /// if `execute` threw (the `try` propagates) or returned `.matches` (the
    /// `guard` records an issue).
    @Test func grepHistoryExecuteReturnsCorrectiveGrepOutputForInvalidRegex() async throws {
        let context = try makeContext()
        // An unbalanced bracket class is not a valid regex; `literal: false`
        // means it is compiled as a pattern, so compilation fails.
        let operation = try GrepHistory(
            GeneratedContent(properties: [
                "pattern": "[invalid", "literal": false,
            ]))

        let output = try await operation.execute(in: context)

        guard case .corrective(let message) = output else {
            Issue.record("expected a .corrective GrepOutput, got \(output)")
            return
        }
        // The corrective carries the exact `ShellStateError.invalidRegex`
        // description: "Invalid regex pattern \"<pattern>\": <underlying>".
        #expect(message.contains("Invalid regex pattern"))
        #expect(message.contains("[invalid"))
    }

    // MARK: - grep history: literal matches exact text, not regex syntax

    @Test func grepHistoryLiteralMatchesEscapedExactTextNotRegexSyntax() async throws {
        let tool = try makeTool()
        // Output containing regex metacharacters: a bracket character class and
        // a `\d+` that, treated as a regex, would NOT match itself verbatim.
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": #"echo 'error[E0001]: \d+ failed'"#,
            ]))

        // With `literal: true` the brackets are matched as literal text — the
        // pattern is pre-escaped — so the exact bracketed token is found.
        let literal = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "grep history", "pattern": "error[E0001]", "literal": true,
            ]))
        #expect(literal.contains("\"total\":1"))
        #expect(literal.contains("error[E0001]"))

        // The same pattern WITHOUT `literal` is an unbalanced/differently-
        // matching regex: `[E0001]` is a character class, so the verbatim
        // `error[E0001]` substring is not matched — no results.
        let asRegex = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "grep history", "pattern": "error[E0001]",
            ]))
        #expect(asRegex.contains("\"total\":0"))
    }

    // MARK: - missing required params → corrective messages

    @Test func grepHistoryMissingRequiredPatternReturnsACorrectiveMessage() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "grep history"]))

        #expect(response.contains("Missing required"))
        #expect(response.contains("pattern"))
        // A corrective message, not a structured match result.
        #expect(!response.contains("\"total\""))
    }

    @Test func getLinesMissingRequiredCommandIdReturnsACorrectiveMessage() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "get lines"]))

        #expect(response.contains("Missing required"))
        #expect(response.contains("command"))
    }

    // MARK: - get lines: unknown id → empty result, not an error

    @Test func getLinesOnAnUnknownCommandIdReturnsAnEmptyResultNotAnError() async throws {
        let tool = try makeTool()

        // No command 999 was ever recorded. This must come back as an empty
        // structured range, not a throw and not a corrective message.
        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "get lines", "command_id": 999,
            ]))

        #expect(response.contains("\"commandId\":999"))
        #expect(response.contains("\"first\":0"))
        #expect(response.contains("\"last\":0"))
        #expect(response.contains("\"lines\":[]"))
    }

    // MARK: - get lines: default range covers the full stored output

    @Test func getLinesWithNoStartOrEndCoversTheFullStoredRange() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'alpha\\nbeta\\ngamma\\n'",
            ]))

        // Omitting start/end retrieves every stored line: 1 through 3.
        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "get lines", "command_id": 1,
            ]))

        #expect(response.contains("\"commandId\":1"))
        #expect(response.contains("\"first\":1"))
        #expect(response.contains("\"last\":3"))
        #expect(response.contains("1: alpha"))
        #expect(response.contains("2: beta"))
        #expect(response.contains("3: gamma"))
    }

    // MARK: - command-id key parity: snake_case vs camelCase

    /// The command-id key resolves identically whether spelled `command_id` or
    /// `commandId`: `get lines` on the same stored command returns byte-identical
    /// `LineRange` output for both spellings. Mirrors the surviving
    /// `working_directory` parity test, closing the split-lost `command_id`
    /// parity gap. Both spellings normalize to the same resolver key, so the
    /// value assertions (`commandId:1` and the stored lines) — not the equality —
    /// are what catch a broken command-id resolution; the equality pins that the
    /// two spellings never diverge from each other.
    @Test func snakeCaseAndCamelCaseCommandIdResolveIdenticallyForGetLines() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'alpha\\nbeta\\ngamma\\n'",
            ]))

        let snake = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "get lines", "command_id": 1,
            ]))
        let camel = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "get lines", "commandId": 1,
            ]))

        // Both spellings resolve to the same command, so the results are identical…
        #expect(snake == camel)
        // …and it is the real stored range, not two identical empties.
        #expect(snake.contains("\"commandId\":1"))
        #expect(snake.contains("1: alpha"))
        #expect(snake.contains("3: gamma"))
    }

    /// The command-id filter key on `grep history` resolves identically whether
    /// spelled `command_id` or `commandId`. Two commands emit the same pattern
    /// with different match counts (2 then 3); filtering to command 1 must scope
    /// to its two matches — not the five across both commands — for either
    /// spelling. The value assertions (`total:2`, `!commandId:2`) — not the
    /// equality — are what catch a broken filter-key resolution: both spellings
    /// normalize together and would degrade to `total:5` in lockstep, so equality
    /// alone would still hold. The equality pins that the two spellings agree.
    @Test func snakeCaseAndCamelCaseCommandIdResolveIdenticallyForGrepHistory() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'MATCH\\nMATCH\\n'",
            ]))
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'MATCH\\nMATCH\\nMATCH\\n'",
            ]))

        let snake = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "grep history", "pattern": "MATCH", "command_id": 1,
            ]))
        let camel = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "grep history", "pattern": "MATCH", "commandId": 1,
            ]))

        // Both spellings resolve to the same filter, so the results are identical…
        #expect(snake == camel)
        // …and scoped to command 1's two matches, not the five across both.
        #expect(snake.contains("\"total\":2"))
        #expect(snake.contains("\"commandId\":1"))
        #expect(!snake.contains("\"commandId\":2"))
    }

    // MARK: - JSON-shape snapshots

    @Test func grepMatchesEncodesTheExpectedFieldNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let result = GrepMatches(
            matches: [
                GrepMatch(commandID: 1, lineNumber: 4, text: "error at line 4"),
                GrepMatch(commandID: 2, lineNumber: 9, text: "error at line 9"),
            ],
            shown: 2,
            total: 7
        )
        let json = try #require(String(data: try encoder.encode(result), encoding: .utf8))

        // The acronym-cased property encodes to the `commandId` wire key.
        #expect(json.contains("\"commandId\":1"))
        #expect(json.contains("\"commandId\":2"))
        #expect(json.contains("\"lineNumber\":4"))
        #expect(json.contains("\"text\":\"error at line 4\""))
        #expect(json.contains("\"shown\":2"))
        // `total` is independent of `shown` — every match, not just those shown.
        #expect(json.contains("\"total\":7"))
        #expect(!json.contains("\"commandID\""))
    }

    @Test func lineRangeEncodesTheExpectedFieldNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let result = LineRange(
            commandID: 3, first: 2, last: 4, lines: ["2: beta", "3: gamma", "4: delta"],
            status: "running")
        let json = try #require(String(data: try encoder.encode(result), encoding: .utf8))

        #expect(json.contains("\"commandId\":3"))
        #expect(json.contains("\"first\":2"))
        #expect(json.contains("\"last\":4"))
        #expect(json.contains("\"lines\":[\"2: beta\",\"3: gamma\",\"4: delta\"]"))
        #expect(json.contains("\"status\":\"running\""))
        #expect(!json.contains("\"commandID\""))

        // An empty range with an unknown status: no lines, both bounds zero
        // (the unknown-id shape), `status` omitted rather than encoded `null`
        // — the same synthesized-optional-encoding technique as
        // `ProcessRow.exitCode`.
        let empty = LineRange(commandID: 5, first: 0, last: 0, lines: [], status: nil)
        let emptyJSON = try #require(String(data: try encoder.encode(empty), encoding: .utf8))
        #expect(emptyJSON.contains("\"commandId\":5"))
        #expect(emptyJSON.contains("\"first\":0"))
        #expect(emptyJSON.contains("\"last\":0"))
        #expect(emptyJSON.contains("\"lines\":[]"))
        #expect(!emptyJSON.contains("\"status\""))
    }

    // MARK: - get lines: waitSeconds — negative value is corrective

    /// Drives `GetLines.execute(in:)` directly, mirroring
    /// `grepHistoryExecuteReturnsCorrectiveGrepOutputForInvalidRegex`: a
    /// negative `waitSeconds` must come back as the pinned corrective
    /// `GetLinesOutput`, not a thrown error and not a `.found` result.
    @Test func getLinesExecuteReturnsCorrectiveOutputForNegativeWaitSeconds() async throws {
        let context = try makeContext()
        let operation = try GetLines(
            GeneratedContent(properties: ["commandID": 1, "waitSeconds": -1]))

        let output = try await operation.execute(in: context)

        guard case .corrective(let message) = output else {
            Issue.record("expected a .corrective GetLinesOutput, got \(output)")
            return
        }
        #expect(message == "waitSeconds must be non-negative")
    }

    @Test func getLinesWithNegativeWaitSecondsReturnsTheCorrectiveMessageThroughTheFusedTool() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "get lines", "command_id": 1, "wait_seconds": -1,
            ]))

        #expect(response.contains("waitSeconds must be non-negative"))
        // A corrective message, not a structured range.
        #expect(!response.contains("\"commandId\""))
    }

    // MARK: - get lines: waitSeconds — lines already available return immediately

    @Test func getLinesReturnsImmediatelyWhenRequestedLinesAreAlreadyAvailableEvenWithWaitSecondsSet()
        async throws
    {
        let context = try makeContext()
        _ = try await ShellRunner(state: context.state).run(
            .init(command: "printf 'alpha\\nbeta\\n'"))

        let operation = try GetLines(
            GeneratedContent(properties: ["commandID": 1, "waitSeconds": 5]))
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await operation.execute(in: context)
        let elapsed = clock.now - start

        guard case .found(let range) = output else {
            Issue.record("expected .found, got \(output)")
            return
        }
        #expect(range.lines == ["1: alpha", "2: beta"])
        #expect(range.status == "completed")
        // No polling needed — this never touched the 5s deadline.
        #expect(elapsed < .seconds(1))
    }

    // MARK: - get lines: waitSeconds — long-poll behavior against a real running child

    /// Polls `context.state.listCommands()` (never through the op under test)
    /// until the background command is registered, so the assertions below
    /// race the real subprocess timing, not Swift's task-scheduling gap.
    private func waitUntilACommandIsRegistered(in context: ShellContext) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await context.state.listCommands().isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func getLinesLongPollReturnsAsSoonAsARunningCommandEmitsARequestedLine() async throws {
        let context = try makeContext()
        let running = Task {
            try await ShellRunner(state: context.state).run(
                .init(command: "sh -c 'sleep 0.5; echo late'"))
        }
        defer { running.cancel() }
        try await waitUntilACommandIsRegistered(in: context)

        let operation = try GetLines(
            GeneratedContent(properties: ["commandID": 1, "waitSeconds": 5]))
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await operation.execute(in: context)
        let elapsed = clock.now - start

        guard case .found(let range) = output else {
            Issue.record("expected .found, got \(output)")
            return
        }
        #expect(range.lines.contains("1: late"))
        // The line landed well before the 5s deadline — the poll loop woke on
        // the new line, not the deadline.
        #expect(elapsed < .seconds(3))

        running.cancel()
        _ = try? await running.value
    }

    @Test func getLinesDeadlineElapsesWithNoNewLinesReturnsEmptyLinesAndRunningStatus() async throws {
        let context = try makeContext()
        let running = Task {
            try await ShellRunner(state: context.state).run(.init(command: "sleep 5"))
        }
        defer { running.cancel() }
        try await waitUntilACommandIsRegistered(in: context)

        let operation = try GetLines(
            GeneratedContent(properties: ["commandID": 1, "waitSeconds": 1]))
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await operation.execute(in: context)
        let elapsed = clock.now - start

        guard case .found(let range) = output else {
            Issue.record("expected .found, got \(output)")
            return
        }
        #expect(range.lines.isEmpty)
        #expect(range.status == "running")
        // Waited roughly the full 1s deadline rather than bailing instantly.
        #expect(elapsed >= .milliseconds(900))

        running.cancel()
        _ = try? await running.value
    }

    @Test func getLinesReturnsPromptlyOnceARunningCommandFinishesWithNoLinesInRange() async throws {
        let context = try makeContext()
        let running = Task {
            try await ShellRunner(state: context.state).run(.init(command: "sleep 0.3"))
        }
        defer { running.cancel() }
        try await waitUntilACommandIsRegistered(in: context)

        let operation = try GetLines(
            GeneratedContent(properties: ["commandID": 1, "waitSeconds": 5]))
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await operation.execute(in: context)
        let elapsed = clock.now - start

        guard case .found(let range) = output else {
            Issue.record("expected .found, got \(output)")
            return
        }
        #expect(range.lines.isEmpty)
        #expect(range.status == "completed")
        // The command finishing ended the poll well before the 5s deadline.
        #expect(elapsed < .seconds(3))

        _ = try? await running.value
    }

    // MARK: - get lines: status field on a finished / unknown command

    @Test func getLinesOnAFinishedCommandReportsItsFinalStatusInJSON() async throws {
        let tool = try makeTool()
        _ = try await tool.call(
            arguments: GeneratedContent(properties: [
                "op": "execute command", "command": "printf 'alpha\\n'",
            ]))

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "get lines", "command_id": 1]))

        #expect(response.contains("\"status\":\"completed\""))
    }

    @Test func getLinesOnAnUnknownCommandIdOmitsTheStatusKeyFromJSON() async throws {
        let tool = try makeTool()

        let response = try await tool.call(
            arguments: GeneratedContent(properties: ["op": "get lines", "command_id": 999]))

        #expect(!response.contains("\"status\""))
    }
}
