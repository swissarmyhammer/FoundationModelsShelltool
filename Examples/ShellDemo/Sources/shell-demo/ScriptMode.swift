// `ScriptMode` — the `shell-demo --script` batch driver.
//
// Reads op lines from standard input and runs them sequentially, in ONE
// process, against ONE `OperationCLIDriver` over ONE fused `shell` tool — so a
// single `ShellContext`/`ShellState` is shared across every line (plan §3's
// one-process-shared-session contract). An `execute command` early in the
// stream is therefore visible to a later `grep history` or `get lines`, exactly
// as it would be to a model calling the tool repeatedly within one turn.
//
// Each line uses the same `<noun> <verb> --options` grammar the default CLI
// mode accepts (e.g. `command execute --command "echo hi"`), so this mode is
// the human-driven twin of `CLIConvergenceTests` and `ExampleIntegrationTests`:
// pipe a script in, read the JSON out. Blank lines and `#` comments are skipped
// so a script can be annotated.

import Foundation
import OperationsCLI
import ShellTool

/// The `shell-demo --script` batch driver: run stdin op lines against one
/// shared session.
enum ScriptMode {
    /// Build the shared tool and driver, then run every op line read from
    /// standard input against them, printing each line's output. Exits non-zero
    /// if the tool could not be built or if any op line failed to parse — the
    /// same exit-code contract the default CLI mode honors, aggregated across
    /// the whole script.
    static func run() async {
        do {
            let driver = try OperationCLIDriver(tool: try ShellTool.make(), executableName: "shell-demo")
            let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let exitCode = await run(input: input, driver: driver) { print($0) }
            if exitCode != 0 {
                exit(exitCode)
            }
        } catch {
            FileHandle.standardError.write(Data("shell-demo: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Run every op line in `input` against `driver`, emitting each non-empty
    /// output through `emit`, and return the aggregate exit code.
    ///
    /// Every line runs against the same `driver` (and thus the same shared
    /// `ShellContext`), so effects accumulate across the script. Blank and
    /// `#`-comment lines are skipped. A line that parses and dispatches — even
    /// to a corrective message — is a success (exit 0, the "return, don't throw"
    /// convention); the aggregate exit code is the first non-zero a line
    /// produced (an ArgumentParser parse failure), or 0 if every line succeeded.
    ///
    /// - Parameters:
    ///   - input: The newline-separated op lines to run.
    ///   - driver: The shared driver every line dispatches through.
    ///   - emit: Sink for each line's non-empty output (the executable prints).
    /// - Returns: The aggregate exit code across all lines.
    static func run(
        input: String,
        driver: OperationCLIDriver,
        emit: (String) -> Void
    ) async -> Int32 {
        var aggregateExitCode: Int32 = 0
        for rawLine in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let result = await driver.run(arguments: tokenize(line))
            if !result.output.isEmpty {
                emit(result.output)
            }
            if aggregateExitCode == 0, result.exitCode != 0 {
                aggregateExitCode = result.exitCode
            }
        }
        return aggregateExitCode
    }

    /// Split one op line into argv the driver can parse, honoring single- and
    /// double-quoted runs so a quoted command (`--command "printf 'a\nb\n'"`)
    /// arrives as one argument with its inner quotes preserved.
    ///
    /// A minimal shell-style word splitter: unquoted whitespace separates words;
    /// a `'…'` or `"…"` run is taken verbatim (its delimiters removed, the other
    /// quote character kept as literal text), and quotes may abut unquoted text
    /// within a single word. An unterminated quote runs to end of line.
    ///
    /// - Parameter line: One op line (already trimmed and non-comment).
    /// - Returns: The argv tokens for `OperationCLIDriver.run(arguments:)`.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?

        for character in line {
            if let openQuote = quote {
                if character == openQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case " ", "\t":
                if inWord {
                    tokens.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(character)
                inWord = true
            }
        }
        if inWord {
            tokens.append(current)
        }
        return tokens
    }
}
