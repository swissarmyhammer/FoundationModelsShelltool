import FoundationModels
import Foundation
import Operations
import OperationsCLI
import Testing

@testable import ShellTool

/// The convergence contract: the `shell` tool's CLI path — an
/// `OperationCLIDriver` over `ShellTool.make(context:)`, the noun-verb grammar
/// the `shell-demo` executable ships — leaves the same effects and returns the
/// same output as the model path (`OperationTool.call` over the fused
/// `AnyOperation`s), for every one of the five operations.
///
/// Both paths funnel through the identical `OperationTool.call(arguments:)`:
/// the CLI path builds the `GeneratedContent` payload from parsed argv, the
/// model path receives it directly. So a given invocation, run once each way
/// against two independent (temp-dir) `ShellContext`s, must converge on the
/// same `ShellState` effect and the same JSON — the point these tests pin.
@Suite struct CLIConvergenceTests {

    // MARK: - Harness

    /// A fused `shell` tool over its own isolated `ShellContext`, plus a driver
    /// over that same tool — the CLI path and model path share one context so a
    /// single harness observes either path's effects.
    private struct Harness {
        let tool: OperationTool<ShellContext>
        let context: ShellContext

        /// A driver over this harness's tool, named as the `shell-demo`
        /// executable presents itself.
        func driver() throws -> OperationCLIDriver {
            try OperationCLIDriver(tool: tool, executableName: "shell-demo")
        }
    }

    /// Build a harness over a `ShellContext` rooted at a unique temp `.shell`
    /// store with a builtin-only policy (no `~/.shell` or project overlay), so
    /// every test is isolated and deterministic — through the real
    /// `ShellTool.make(context:)` factory, the same wiring the executable ships.
    private func makeHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-cli-test-\(UUID().uuidString)", isDirectory: true)
        let state = try ShellState(preferredDirectory: directory)
        let policy = ShellPolicy(userConfigURL: nil, projectConfigURL: nil, warn: { _ in })
        let context = ShellContext(state: state, policy: policy)
        return Harness(tool: try ShellTool.make(context: context), context: context)
    }

    /// A deterministic projection of a `ShellState`'s effects — every command
    /// record's stable fields plus its stored lines, excluding the wall-clock
    /// start and elapsed duration that vary run to run. This is the "resulting
    /// `ShellState` effects" the convergence contract compares.
    private struct CommandEffect: Equatable {
        let id: Int
        let command: String
        let status: String
        let exitCode: Int?
        let lineCount: Int
        let lines: [String]
    }

    /// Snapshot `context`'s command history as comparable `CommandEffect`s.
    private func effects(of context: ShellContext) async throws -> [CommandEffect] {
        var effects: [CommandEffect] = []
        for record in await context.state.listCommands() {
            let lines = try await context.state.getLines(commandID: record.id)
                .map { "\($0.lineNumber): \($0.text)" }
            effects.append(
                CommandEffect(
                    id: record.id,
                    command: record.command,
                    status: record.status.rawValue,
                    exitCode: record.exitCode,
                    lineCount: record.lineCount,
                    lines: lines
                ))
        }
        return effects
    }

    // MARK: - execute command

    @Test func executeCommandConvergesAcrossCLIAndModelPaths() async throws {
        let cli = try makeHarness()
        let model = try makeHarness()

        let cliResult = await (try cli.driver()).run(
            arguments: ["command", "execute", "--command", "echo hi"])
        let modelJSON = try await model.tool.call(
            arguments: GeneratedContent(properties: ["op": "execute command", "command": "echo hi"]))

        // The CLI run succeeded and produced the command's JSON.
        #expect(cliResult.exitCode == 0)
        #expect(cliResult.output.contains("\"commandId\":1"))
        #expect(modelJSON.contains("\"commandId\":1"))

        // The two paths left identical, deterministic effects.
        let cliEffects = try await effects(of: cli.context)
        let modelEffects = try await effects(of: model.context)
        #expect(cliEffects == modelEffects)
        #expect(
            cliEffects == [
                CommandEffect(
                    id: 1, command: "echo hi", status: "completed",
                    exitCode: 0, lineCount: 1, lines: ["1: hi"])
            ])
    }

    // MARK: - list processes

    @Test func listProcessesConvergesAcrossCLIAndModelPaths() async throws {
        let cli = try makeHarness()
        let model = try makeHarness()

        // Seed both histories identically so `list` has a row to render.
        try await seed(cli, model, command: "echo seed")

        let cliResult = await (try cli.driver()).run(arguments: ["processes", "list"])
        let modelJSON = try await model.tool.call(
            arguments: GeneratedContent(properties: ["op": "list processes"]))

        #expect(cliResult.exitCode == 0)
        // `list processes` rows carry the volatile `startedAt`/`duration`; strip
        // those and the remaining stable fields must match across the two paths.
        let cliRows = try stableProcessRows(cliResult.output)
        let modelRows = try stableProcessRows(modelJSON)
        #expect(cliRows == modelRows)
        // Guard against a vacuous pass: the single seeded command must actually
        // surface as a row, so the equality above is comparing real content.
        #expect(cliRows.count == 1)
        #expect(cliRows.first?["command"] == "echo seed")
    }

    // MARK: - grep history

    @Test func grepHistoryConvergesAcrossCLIAndModelPaths() async throws {
        let cli = try makeHarness()
        let model = try makeHarness()
        try await seed(cli, model, command: "printf 'MARK\\nMARK\\n'")

        let cliResult = await (try cli.driver()).run(
            arguments: ["history", "grep", "--pattern", "MARK"])
        let modelJSON = try await model.tool.call(
            arguments: GeneratedContent(properties: ["op": "grep history", "pattern": "MARK"]))

        #expect(cliResult.exitCode == 0)
        // `grep history`'s output carries no volatile fields — the two paths
        // produce byte-identical JSON.
        #expect(cliResult.output == modelJSON)
        #expect(cliResult.output.contains("\"total\":2"))
    }

    // MARK: - get lines

    @Test func getLinesConvergesAcrossCLIAndModelPaths() async throws {
        let cli = try makeHarness()
        let model = try makeHarness()
        try await seed(cli, model, command: "printf 'alpha\\nbeta\\n'")

        let cliResult = await (try cli.driver()).run(
            arguments: ["lines", "get", "--command-id", "1"])
        let modelJSON = try await model.tool.call(
            arguments: GeneratedContent(properties: ["op": "get lines", "command_id": 1]))

        #expect(cliResult.exitCode == 0)
        #expect(cliResult.output == modelJSON)
        #expect(cliResult.output.contains("1: alpha"))
        #expect(cliResult.output.contains("2: beta"))
    }

    // MARK: - get lines: waitSeconds exposed with no short flag

    /// `waitSeconds` has no `@OperationParam(short:)`, so its only CLI form is
    /// the long `--wait-seconds` option (ArgumentParser's default kebab-case
    /// derivation from the property name) — pinned so `get lines` and the
    /// future `execute command` `waitSeconds` cannot diverge. The requested
    /// lines are already stored, so passing it never engages the poll loop.
    @Test func getLinesWaitSecondsCLIFlagConvergesWithTheModelPathAndReturnsPromptly() async throws {
        let cli = try makeHarness()
        let model = try makeHarness()
        try await seed(cli, model, command: "printf 'alpha\\nbeta\\n'")

        let cliResult = await (try cli.driver()).run(
            arguments: ["lines", "get", "--command-id", "1", "--wait-seconds", "5"])
        let modelJSON = try await model.tool.call(
            arguments: GeneratedContent(properties: [
                "op": "get lines", "command_id": 1, "waitSeconds": 5,
            ]))

        #expect(cliResult.exitCode == 0)
        #expect(cliResult.output == modelJSON)
        #expect(cliResult.output.contains("1: alpha"))
        #expect(cliResult.output.contains("2: beta"))
    }

    // MARK: - kill process

    @Test func killProcessConvergesAcrossCLIAndModelPaths() async throws {
        let cli = try makeHarness()
        let model = try makeHarness()

        // An unknown id has no running process, so the op returns its corrective
        // message rather than throwing — the two paths converge on that string.
        let cliResult = await (try cli.driver()).run(
            arguments: ["process", "kill", "--id", "999"])
        let modelJSON = try await model.tool.call(
            arguments: GeneratedContent(properties: ["op": "kill process", "id": 999]))

        // A corrective-message run exits 0 (the op returned, it did not throw) —
        // the upstream "return, don't throw" convention, confirmed at runtime.
        #expect(cliResult.exitCode == 0)
        #expect(cliResult.output == modelJSON)
        #expect(cliResult.output.contains("No running process"))
    }

    // MARK: - exit-code propagation

    @Test func missingRequiredArgumentExitsNonZero() async throws {
        let cli = try makeHarness()

        // `command execute` with no `--command` is an ArgumentParser validation
        // failure — a genuine error, so the run exits non-zero (the other side
        // of the corrective-message-exits-0 contract).
        let result = await (try cli.driver()).run(arguments: ["command", "execute"])

        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
    }

    // MARK: - help

    @Test func rootHelpListsEveryNoun() async throws {
        let cli = try makeHarness()

        let result = await (try cli.driver()).run(arguments: ["--help"])

        for noun in ["command", "processes", "process", "history", "lines"] {
            #expect(result.output.contains(noun))
        }
    }

    @Test func nounHelpListsItsVerb() async throws {
        let cli = try makeHarness()
        let driver = try cli.driver()

        let nounVerbs: [(noun: String, verb: String)] = [
            ("command", "execute"), ("processes", "list"), ("process", "kill"),
            ("history", "grep"), ("lines", "get"),
        ]
        for nounVerb in nounVerbs {
            let result = await driver.run(arguments: [nounVerb.noun, "--help"])
            #expect(result.output.contains(nounVerb.verb))
        }
    }

    // MARK: - unknown noun/verb and did-you-mean

    @Test func unknownNounFailsLoudlyWithUsageInsteadOfSilently() async throws {
        let cli = try makeHarness()

        // An unknown noun is not silently ignored: ArgumentParser rejects it
        // with a non-zero exit and usage text pointing at `--help`.
        let result = await (try cli.driver()).run(arguments: ["commnd", "execute"])

        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("shell-demo"))
        #expect(result.output.contains("--help"))
    }

    @Test func unknownVerbFailsLoudlyWithUsageInsteadOfSilently() async throws {
        let cli = try makeHarness()

        // Same for an unknown verb under a valid noun — the `command` node's
        // usage is shown, non-zero exit, never a silent no-op.
        let result = await (try cli.driver()).run(arguments: ["command", "exec"])

        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
        #expect(result.output.contains("shell-demo command"))
        #expect(result.output.contains("--help"))
    }

    @Test func nearMissOptionYieldsStockDidYouMeanSuggestion() async throws {
        let cli = try makeHarness()

        // A near-miss option is where stock ArgumentParser's did-you-mean fires:
        // `--timout` (required `--command` supplied) is diagnosed as the
        // misspelling it is, suggesting the real `--timeout` — no hand-rolled
        // parsing involved.
        let result = await (try cli.driver()).run(
            arguments: ["command", "execute", "--command", "echo hi", "--timout", "5"])

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Did you mean"))
        #expect(result.output.contains("--timeout"))
    }

    // MARK: - public factory (the executable's entry point)

    @Test func publicFactoryAssemblesADriverThatRunsACommand() async throws {
        // The `shell-demo` executable can't build a `ShellContext` — it is
        // internal — so it goes through the contextless `ShellTool.make(...)`
        // factory. This exercises exactly that public path (no `@testable`
        // context), differing only in pointing the store at a temp dir.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltool-cli-factory-\(UUID().uuidString)", isDirectory: true)
        let tool = try ShellTool.make(preferredDirectory: directory)
        let driver = try OperationCLIDriver(tool: tool, executableName: "shell-demo")

        let result = await driver.run(arguments: ["command", "execute", "--command", "echo hi"])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("\"commandId\":1"))
        #expect(result.output.contains("1: hi"))
    }

    // MARK: - helpers

    /// Apply the same `execute command` seed to both harnesses' histories,
    /// through the model path, so a later read op has identical state to serve.
    private func seed(_ harnesses: Harness..., command: String) async throws {
        for harness in harnesses {
            _ = try await harness.tool.call(
                arguments: GeneratedContent(properties: ["op": "execute command", "command": command]))
        }
    }

    /// Decode a `list processes` JSON array and project each row to its stable
    /// fields, dropping the volatile `startedAt` and `duration` — so two runs
    /// that started at different instants still compare equal.
    private func stableProcessRows(_ json: String) throws -> [[String: String]] {
        let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
        return array.map { row in
            var stable: [String: String] = [:]
            for (key, value) in row where key != "startedAt" && key != "duration" {
                stable[key] = "\(value)"
            }
            return stable
        }
    }
}
