import Testing

/// Unit coverage for `ReadmeSnippets.parse(_:)` against synthetic fixtures,
/// independent of the real `README.md` — proves the parser accepts a
/// well-formed `doc-snippet` block and skips malformed ones, matching the
/// format contract in its docstring.
///
/// Mirrors the `DocCoverageScannerTests.swift` convention of fixture-level unit
/// tests for a parser whose integration test runs against real files.
@Suite("ReadmeSnippets parser")
struct ReadmeSnippetsParserTests {
    @Test("a well-formed doc-snippet block parses to one snippet")
    func wellFormedBlockParsesToOneSnippet() throws {
        let readme = """
            <!-- doc-snippet source="Sources/ShellTool/ShellTool.swift" -->
            ```swift
            let x = 1
            ```
            <!-- /doc-snippet -->
            """
        let snippets = try ReadmeSnippets.parse(readme)
        #expect(snippets.count == 1)
        #expect(snippets.first?.sourcePath == "Sources/ShellTool/ShellTool.swift")
        #expect(snippets.first?.code == "let x = 1")
    }

    @Test("a block whose closing marker is missing is skipped")
    func blockMissingClosingMarkerIsSkipped() throws {
        let readme = """
            <!-- doc-snippet source="Sources/ShellTool/ShellTool.swift" -->
            ```swift
            let x = 1
            ```
            """
        #expect(try ReadmeSnippets.parse(readme).isEmpty)
    }

    @Test("a block whose closing marker is some other text is skipped")
    func blockWithWrongClosingMarkerIsSkipped() throws {
        let readme = """
            <!-- doc-snippet source="Sources/ShellTool/ShellTool.swift" -->
            ```swift
            let x = 1
            ```
            <!-- not the closing marker -->
            """
        #expect(try ReadmeSnippets.parse(readme).isEmpty)
    }

    @Test("a marker with no following fence is skipped")
    func markerWithNoFollowingFenceIsSkipped() throws {
        let readme = """
            <!-- doc-snippet source="Sources/ShellTool/ShellTool.swift" -->
            just prose, no fence
            """
        #expect(try ReadmeSnippets.parse(readme).isEmpty)
    }

    @Test("a four-backtick fence is not closed early by an inner three-backtick line")
    func fourBacktickFenceIsNotClosedByInnerThreeBacktickLine() throws {
        let readme = """
            <!-- doc-snippet source="Sources/ShellTool/ShellTool.swift" -->
            ````swift
            let x = 1
            ```
            let y = 2
            ````
            <!-- /doc-snippet -->
            """
        let snippets = try ReadmeSnippets.parse(readme)
        #expect(snippets.count == 1)
        #expect(snippets.first?.sourcePath == "Sources/ShellTool/ShellTool.swift")
        #expect(snippets.first?.code == "let x = 1\n```\nlet y = 2")
    }

    @Test("a well-formed block after a malformed one is still parsed")
    func wellFormedBlockAfterMalformedOneIsStillParsed() throws {
        let readme = """
            <!-- doc-snippet source="Sources/ShellTool/First.swift" -->
            ```swift
            let a = 1
            ```

            <!-- doc-snippet source="Sources/ShellTool/Second.swift" -->
            ```swift
            let b = 2
            ```
            <!-- /doc-snippet -->
            """
        let snippets = try ReadmeSnippets.parse(readme)
        #expect(snippets.count == 1)
        #expect(snippets.first?.sourcePath == "Sources/ShellTool/Second.swift")
    }
}
