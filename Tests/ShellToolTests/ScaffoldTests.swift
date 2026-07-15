import Testing

@testable import ShellTool

/// Scaffolding smoke test for the `ShellTool` module.
///
/// The `@testable import ShellTool` above is the real assertion: it only
/// compiles and links if the `ShellTool` library target builds and exposes an
/// importable module. Reaching and running this `@Test` under `swift test`
/// therefore proves both that the module imports cleanly and that the package's
/// test target executes — no tautological runtime assertion is needed.
///
/// Real behavioral tests for the shell operations replace this smoke test
/// alongside the implementation in the subsequent tasks.
@Suite struct ShellToolScaffoldTests {
    @Test func moduleImportsCleanlyAndTestTargetRuns() {}
}
