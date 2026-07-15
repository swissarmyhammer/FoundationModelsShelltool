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

    /// Build a fresh tool over a `ShellContext` rooted at a unique temp `.shell`
    /// store, with a builtin-only policy (no `~/.shell` or project overlay), so
    /// every test is isolated and deterministic. `execute command` is fused in
    /// alongside the two history ops so a test can produce output and then
    /// grep / get-lines the same `ShellState`.
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
            commandID: 3, first: 2, last: 4, lines: ["2: beta", "3: gamma", "4: delta"])
        let json = try #require(String(data: try encoder.encode(result), encoding: .utf8))

        #expect(json.contains("\"commandId\":3"))
        #expect(json.contains("\"first\":2"))
        #expect(json.contains("\"last\":4"))
        #expect(json.contains("\"lines\":[\"2: beta\",\"3: gamma\",\"4: delta\"]"))
        #expect(!json.contains("\"commandID\""))

        // An empty range: no lines, both bounds zero (the unknown-id shape).
        let empty = LineRange(commandID: 5, first: 0, last: 0, lines: [])
        let emptyJSON = try #require(String(data: try encoder.encode(empty), encoding: .utf8))
        #expect(emptyJSON.contains("\"commandId\":5"))
        #expect(emptyJSON.contains("\"first\":0"))
        #expect(emptyJSON.contains("\"last\":0"))
        #expect(emptyJSON.contains("\"lines\":[]"))
    }
}
