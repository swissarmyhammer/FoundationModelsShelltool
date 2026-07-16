// `ShellDemoDriver` — the CLI driver, name, and run skeleton shared by the
// default CLI and `--script` modes.
//
// Both entry points — `ShellDemoMain.runCLI` and `ScriptMode.run` — drive argv
// through an `OperationCLIDriver` over the same fused `shell` tool assembled by
// the contextless `ShellTool.make()` factory (rooted at `<cwd>/.shell`), under
// the same executable name and the same exit-code/error-propagation contract.
// All three — the name, the construction, and the failure/exit skeleton — live
// here once, so the two modes cannot drift apart.
//
// The `--chat` mode is deliberately absent here: it registers the tool on a
// `LanguageModelSession` rather than a CLI driver — a genuinely different
// composition — so it builds its tool directly.

import Foundation
import OperationsCLI
import ShellTool

/// Factory, shared identity, and run skeleton for the `OperationCLIDriver` used
/// by the default CLI and `--script` modes.
enum ShellDemoDriver {
    /// The name shown in the driver's usage/help text and error prefixes.
    static let executableName = "shell-demo"

    /// Builds an `OperationCLIDriver` over the fused `shell` tool from
    /// `ShellTool.make()` (rooted at `<cwd>/.shell`).
    ///
    /// - Returns: A driver ready to dispatch the noun-verb grammar under
    ///   `executableName`.
    /// - Throws: Rethrows from `ShellTool.make()` or the driver's initializer.
    static func make() throws -> OperationCLIDriver {
        try OperationCLIDriver(tool: try ShellTool.make(), executableName: executableName)
    }

    /// Runs `body` against a freshly built driver, exiting with the non-zero
    /// code it returns or reporting a thrown error and exiting 1.
    ///
    /// This is the failure/exit skeleton both CLI entry points share: build the
    /// driver once, run the mode's work against it, and honor the same
    /// exit-code and error-propagation contract — a run that returns 0 falls
    /// through without exiting, a non-zero code exits with it, and a thrown
    /// error prints `executableName: <error>` to standard error before exiting
    /// 1.
    ///
    /// - Parameter body: The mode's work, given the shared driver, returning its
    ///   exit code.
    static func run(_ body: (OperationCLIDriver) async throws -> Int32) async {
        do {
            let driver = try make()
            let exitCode = try await body(driver)
            if exitCode != 0 {
                exit(exitCode)
            }
        } catch {
            FileHandle.standardError.write(Data("\(executableName): \(error)\n".utf8))
            exit(1)
        }
    }
}
