// `ChatValidationHarness` — the `shell-demo --chat` live-model validation.
//
// The full-stack analogue of the upstream `notes --chat` harness, adapted to
// the shell tool's scenarios. It registers the fused `shell` tool on a
// `LanguageModelSession` and drives a scripted prompt set that exercises the
// tool's four signature behaviors:
//
//   - long output → tail note → follow-up: run a command whose output exceeds
//     the 32-line tail, so the model sees the "showing last 32 of N lines" note
//     and follows up with `grep history` / `get lines` to read the rest;
//   - corrective kill recovery: ask to kill a command that has already
//     finished, so `ShellState.killProcess` throws `noRunningProcess` and the
//     model sees the "No running process" corrective message rather than a
//     thrown error;
//   - soft-deadline detach and the polling protocol it opens up: start a long
//     `sleep` bounded by a short `waitSeconds` so `execute command` comes back
//     `running` instead of blocking to completion, keep reading its output
//     with `get lines`'s own `waitSeconds` long-poll, then `kill process` it
//     while it is genuinely still running — the flagship "execute → running →
//     get lines long-poll → kill" protocol (see `DESIGN_NOTES.md` §13/§14);
//   - denied command recovery: ask for `sudo rm -rf /`, which `ShellPolicy`
//     rejects with a corrective message, and confirm the model rephrases within
//     the retry cap rather than looping forever.
//
// It reports op-call accuracy over the scripted set, the fused tool's rendered
// schema size via `tokenCount(for:)`, and the retry-cap behavior on the denied
// command.
//
// MANUAL-RUN ONLY — never part of `swift test`. It needs an Apple
// Intelligence-enabled device, which CI does not have (plan §7.4): `run()`
// degrades to a skip message off-device instead of failing, so invoking it in
// CI is harmless. The automated suite documents this exclusion explicitly in
// `ExampleIntegrationTests.chatModeIsExcludedFromTheAutomatedSuite`.

import FoundationModels
import Operations
import ShellTool

/// Drives the scripted live-model validation `shell-demo --chat` runs.
enum ChatValidationHarness {
    /// Represents a scripted prompt paired with the op the shell tool should dispatch.
    private struct ScriptedPrompt: Sendable {
        /// Stores the natural-language prompt sent to the model.
        let prompt: String
        /// Identifies the `"verb noun"` op string the model is expected to dispatch.
        let expectedOp: String
    }

    /// Lists the scripted prompts, in execution order.
    ///
    /// Covers long commands, truncation follow-ups, corrective kills, and
    /// soft-deadline detach flows. Each targets one shell operation. Before the soft-deadline detach work
    /// (kanban task `01KY5PDG4B3WH44FR1ZYCJKMWJ` / `ycjkmwj`), `execute
    /// command` always blocked to completion, so a `sleep 60` prompt here
    /// would already have finished by the time a later "kill it" prompt ran —
    /// that accidentally exercised the *corrective* "No running process" path
    /// instead of a genuine kill. The prompts below are re-pointed so each one
    /// deliberately targets its intended path: prompt 4 below is the
    /// corrective-kill scenario (killing command 1, the already-finished `seq
    /// 1 100`), and prompts 5–8 are the genuine-kill scenario, going through
    /// `waitSeconds` detach and `get lines`'s long-poll first so the command
    /// really is still running when the kill lands.
    private static let scriptedPrompts: [ScriptedPrompt] = [
        ScriptedPrompt(
            prompt: "Run the command `seq 1 100` and show me its output.",
            expectedOp: "execute command"),
        ScriptedPrompt(
            prompt: "That output was truncated to the last 32 lines. Search the command history for the line that is exactly '50'.",
            expectedOp: "grep history"),
        ScriptedPrompt(
            prompt: "Now show me lines 1 through 5 of that command's output.",
            expectedOp: "get lines"),
        ScriptedPrompt(
            prompt:
                "That `seq 1 100` command (command id 1) has already finished. Try to kill it anyway, just to confirm it's not running.",
            expectedOp: "kill process"),
        ScriptedPrompt(
            prompt:
                "Run `sleep 60` in the background, but don't wait more than 2 seconds for it — return control to me even if it's still going.",
            expectedOp: "execute command"),
        ScriptedPrompt(
            prompt:
                "Keep checking that sleep command's output — wait up to 5 seconds for new lines to show up before giving up.",
            expectedOp: "get lines"),
        ScriptedPrompt(
            prompt: "List all the commands you've run so far with their status.",
            expectedOp: "list processes"),
        ScriptedPrompt(
            prompt: "That sleep command is genuinely still running in the background right now — kill it.",
            expectedOp: "kill process"),
    ]

    /// Represents a command that `ShellPolicy` denies, for observing the corrective message.
    ///
    /// Also used to observe the retry-cap behavior when the model tries to
    /// recover from it.
    private static let deniedCommandPrompt =
        "Delete every file on this machine by running `sudo rm -rf /`."

    /// Bounds how many times `probeRetryCapBehavior` resends `deniedCommandPrompt`.
    private static let deniedCommandProbeRetryAttempts = 3

    /// Specifies the instructions the harness's `LanguageModelSession` runs under.
    private static let sessionInstructions =
        "You operate a virtual shell using the shell tool. Always use the tool to run commands, inspect their output, and manage processes."

    /// Maps unavailability reasons to human-readable text.
    ///
    /// Keyed by the reason's case name via `String(describing:)`. A reason
    /// absent from the table — including any future `@unknown` case —
    /// falls back to `unknownAvailabilityReasonText`.
    private static let availabilityReasonMessages: [String: String] = [
        "deviceNotEligible": "device not eligible",
        "appleIntelligenceNotEnabled": "Apple Intelligence not enabled",
        "modelNotReady": "model not ready",
    ]

    /// Provides the fallback text used for unavailability reasons not in `availabilityReasonMessages`.
    private static let unknownAvailabilityReasonText = "unknown reason"

    /// Holds the shared suffix of the skip messages that `run()` prints when the model is unavailable, so phrasing lives in one place across both paths.
    private static let skipValidationMessage = "skipping live validation."

    /// Represents the placeholder string shown when a response produced no tool call.
    ///
    /// Used in the op-call accuracy and retry-cap logs.
    private static let noOpText = "none"

    /// Runs the live-model validation if `SystemLanguageModel` is available on this device; otherwise prints a skip message.
    ///
    /// Never fails outright, so a CI run of `--chat` exits cleanly.
    static func run() async {
        switch SystemLanguageModel.default.availability {
        case .available:
            await runValidation()
        case .unavailable(let reason):
            let reasonText = availabilityReasonMessages[String(describing: reason)]
                ?? unknownAvailabilityReasonText
            print("Foundation Models unavailable on this device (\(reasonText)); \(skipValidationMessage)")
        @unknown default:
            print("Foundation Models availability is unknown on this device; \(skipValidationMessage)")
        }
    }

    /// Runs every stage of the validation report in turn.
    private static func runValidation() async {
        do {
            try await reportTokenCount()

            let tool = try ShellTool.make()
            let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
            let accuracy = await measureOpCallAccuracy(session: session, toolName: tool.name)
            print("Op-call accuracy: \(accuracy.matched)/\(accuracy.total) scripted prompts dispatched the expected op.")

            await probeRetryCapBehavior(session: session)
        } catch {
            print("Live validation failed: \(error)")
        }
    }

    /// Reports the token count of the fused tool's rendered schema.
    ///
    /// Printed so the schema-in-prompt cost is observable.
    ///
    /// - Throws: Rethrows from `ShellTool.make()` or
    ///   `SystemLanguageModel.tokenCount(for:)`.
    private static func reportTokenCount() async throws {
        guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else {
            print("Token-count reporting requires macOS/iOS/visionOS 26.4 or newer; skipping.")
            return
        }
        let count = try await SystemLanguageModel.default.tokenCount(for: [try ShellTool.make()])
        print("Fused shell tool schema token count: \(count)")
    }

    /// Measures how many scripted prompts dispatch their expected operations.
    ///
    /// - Parameters:
    ///   - session: The session to send scripted prompts to.
    ///   - toolName: The fused tool's name, to find its calls in the session's
    ///     transcript after each response.
    /// - Returns: The number of prompts that matched, out of the total.
    private static func measureOpCallAccuracy(
        session: LanguageModelSession,
        toolName: String
    ) async -> (matched: Int, total: Int) {
        var matched = 0
        for scripted in scriptedPrompts
        where await evaluateScriptedPrompt(scripted: scripted, session: session, toolName: toolName) {
            matched += 1
        }
        return (matched, scriptedPrompts.count)
    }

    /// Evaluates a scripted prompt and returns whether its tool call matched the expected operation.
    ///
    /// - Parameters:
    ///   - scripted: The prompt and its expected op string.
    ///   - session: The session to send the prompt to.
    ///   - toolName: The fused tool's name, to find its call in the transcript.
    /// - Returns: Whether the dispatched op matched `scripted.expectedOp`.
    private static func evaluateScriptedPrompt(
        scripted: ScriptedPrompt,
        session: LanguageModelSession,
        toolName: String
    ) async -> Bool {
        do {
            _ = try await session.respond(to: scripted.prompt)
            let actual = lastToolCallOp(in: session.transcript, toolName: toolName)
            let matched = actual == scripted.expectedOp
            let status = matched ? "OK" : "MISS"
            print("[\(status)] \"\(scripted.prompt)\" -> expected '\(scripted.expectedOp)', got '\(actual ?? noOpText)'")
            return matched
        } catch {
            print("[ERROR] \"\(scripted.prompt)\" -> \(error)")
            return false
        }
    }

    /// Probes retry-cap behavior by repeatedly sending a policy-denied command.
    ///
    /// `ShellPolicy` denies `sudo rm -rf /` with a corrective message; this
    /// confirms the model rephrases or gives up within the retry cap rather
    /// than looping forever.
    ///
    /// - Parameter session: The session to send the probe requests to.
    private static func probeRetryCapBehavior(session: LanguageModelSession) async {
        print("Retry-cap probe: sending a policy-denied command up to \(deniedCommandProbeRetryAttempts) times to observe corrective recovery.")
        for attempt in 1...deniedCommandProbeRetryAttempts {
            do {
                let response = try await session.respond(to: deniedCommandPrompt)
                let op = lastToolCallOp(in: session.transcript, toolName: ShellTool.name)
                print("[attempt \(attempt)] dispatched op '\(op ?? noOpText)'; model responded: \(response.content)")
            } catch {
                print("[attempt \(attempt)] session threw: \(error)")
            }
        }
    }

    /// Returns the op of the most recent tool call matching the given tool name, or nil if none.
    ///
    /// - Parameters:
    ///   - transcript: The session transcript to search.
    ///   - toolName: The tool name to match `Transcript.ToolCall.toolName`
    ///     against.
    /// - Returns: The op string of the most recent matching call, or nil if none found.
    private static func lastToolCallOp(in transcript: Transcript, toolName: String) -> String? {
        var lastMatch: String?
        for entry in transcript {
            guard case .toolCalls(let calls) = entry else { continue }
            if let match = findMatchingCallOp(calls: calls, toolName: toolName) {
                lastMatch = match
            }
        }
        return lastMatch
    }

    /// Returns the op argument of the last call in `calls` whose tool name matches `toolName`, or nil if none match.
    ///
    /// - Parameters:
    ///   - calls: The tool calls from one transcript entry to search.
    ///   - toolName: The tool name to match `Transcript.ToolCall.toolName` against.
    /// - Returns: The op argument of the last matching call, or nil if none found.
    private static func findMatchingCallOp(calls: Transcript.ToolCalls, toolName: String) -> String? {
        var lastMatch: String?
        for call in calls where call.toolName == toolName {
            lastMatch = try? call.arguments.value(String.self, forProperty: OperationKeys.opFieldName)
        }
        return lastMatch
    }
}
