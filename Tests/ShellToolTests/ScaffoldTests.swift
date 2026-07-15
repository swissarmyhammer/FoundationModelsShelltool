import Testing

@testable import ShellTool

/// Scaffolding smoke test: proves the `ShellTool` module builds and links and
/// that the package's test target runs under `swift test`. Real behavioral
/// tests for the shell operations land alongside them in task 2.
@Suite struct ShellToolScaffoldTests {
    @Test func packageScaffoldingBuildsAndTestsRun() {
        #expect(Bool(true))
    }
}
