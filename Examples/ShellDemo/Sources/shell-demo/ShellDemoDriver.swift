// `ShellDemoDriver` — the CLI driver shared by the default CLI and `--script`
// modes.
//
// Both entry points — `ShellDemoMain.runCLI` and `ScriptMode.run` — drive argv
// through an `OperationCLIDriver` over the same fused `shell` tool assembled by
// the contextless `ShellTool.make()` factory (rooted at `<cwd>/.shell`). This
// factory is the single place that construction lives, so the two modes cannot
// drift apart.
//
// The `--chat` mode is deliberately absent here: it registers the tool on a
// `LanguageModelSession` rather than a CLI driver — a genuinely different
// composition — so it builds its tool directly.

import OperationsCLI
import ShellTool

/// Factory for the `OperationCLIDriver` shared by the default CLI and `--script`
/// modes.
enum ShellDemoDriver {
    /// Builds an `OperationCLIDriver` over the fused `shell` tool from
    /// `ShellTool.make()` (rooted at `<cwd>/.shell`).
    ///
    /// - Parameter executableName: The name shown in the driver's usage/help
    ///   text and error prefixes.
    /// - Returns: A driver ready to dispatch the noun-verb grammar.
    /// - Throws: Rethrows from `ShellTool.make()` or the driver's initializer.
    static func make(executableName: String) throws -> OperationCLIDriver {
        try OperationCLIDriver(tool: try ShellTool.make(), executableName: executableName)
    }
}
