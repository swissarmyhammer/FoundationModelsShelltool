import Foundation
import Testing

/// Verifies the "Docs" task's "README example compiles against the actual
/// package" acceptance criterion: every
/// `<!-- doc-snippet source="..." --> ``` ... ``` <!-- /doc-snippet -->` code
/// block in the repo root's `README.md` is a genuine, contiguous excerpt of the
/// source file it cites, not hand-written pseudocode that could drift out of
/// sync with what actually compiles. The declare → fuse → session → CLI
/// walkthrough is cited from the real `Sources/ShellTool` library and the
/// `Examples/ShellDemo` executable, so `swift test` fails the moment a README
/// snippet no longer matches the code it claims to show.
///
/// Mirrors the upstream `FoundationModelsOperationTool`'s
/// `ReadmeSnippetTests.swift` mechanism, scoped to this package's single
/// `README.md` (which carries all four stages inline, rather than splitting a
/// separate guide out).
@Suite("README code-snippet provenance")
struct ReadmeSnippetTests {
    /// The doc-snippet-bearing markdown files, relative to the package root.
    private static let docFiles = ["README.md"]

    @Test("every doc-snippet code block is a real, contiguous excerpt of its cited source file", arguments: docFiles)
    func everySnippetIsARealContiguousExcerptOfItsSource(docFile: String) throws {
        let snippets = try ReadmeSnippets.parse(fileContents(relativePath: docFile))
        #expect(!snippets.isEmpty, "expected \(docFile) to contain at least one <!-- doc-snippet --> block")

        for snippet in snippets {
            let sourceLines = try sourceFileLines(relativePath: snippet.sourcePath)
            #expect(
                ReadmeSnippets.isContiguousExcerpt(snippet.code, of: sourceLines),
                Comment(rawValue: "\(docFile) snippet citing '\(snippet.sourcePath)' is not a contiguous excerpt of that file")
            )
        }
    }

    @Test("a doc-snippet source path that escapes the package root is rejected")
    func sourcePathOutsideThePackageRootIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try sourceFileLines(relativePath: "../../../../../../etc/passwd")
        }
    }

    @Test("a doc-file path that escapes the package root is rejected")
    func docFilePathOutsideThePackageRootIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try fileContents(relativePath: "../../../../../../etc/passwd")
        }
    }

    @Test("the README documents all four declare/fuse/session/CLI stages from real source")
    func readmeDocumentsAllFourStages() throws {
        var sourcePaths: Set<String> = []
        for docFile in Self.docFiles {
            let snippets = try ReadmeSnippets.parse(fileContents(relativePath: docFile))
            sourcePaths.formUnion(snippets.map(\.sourcePath))
        }

        // declare: an @Operation-declared operation struct.
        #expect(sourcePaths.contains("Sources/ShellTool/Operations/ExecuteCommand.swift"))
        // fuse: the five operations fused into one OperationTool.
        #expect(sourcePaths.contains("Sources/ShellTool/ShellTool.swift"))
        // session: the fused tool registered on a LanguageModelSession.
        #expect(sourcePaths.contains("Examples/ShellDemo/Sources/shell-demo/ChatValidationHarness.swift"))
        // CLI: the same tool driven through an OperationCLIDriver.
        #expect(sourcePaths.contains("Examples/ShellDemo/Sources/shell-demo/ShellDemoDriver.swift"))
    }

    private func fileContents(relativePath: String) throws -> String {
        let root = PackageRootValidation.packageRoot()
        let fileURL = root.appendingPathComponent(relativePath)
        try PackageRootValidation.requireWithinPackageRoot(fileURL, root: root) {
            PathEscapesPackageRoot(path: $0)
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func sourceFileLines(relativePath: String) throws -> [String] {
        try fileContents(relativePath: relativePath).components(separatedBy: "\n")
    }

    /// A source path cited by a README `doc-snippet` marker resolved outside
    /// the package root — e.g. via a `..` component.
    private struct PathEscapesPackageRoot: Error, CustomStringConvertible {
        let path: String
        var description: String { "'\(path)' resolves outside the package root" }
    }
}

/// Parses `<!-- doc-snippet source="..." -->` blocks out of a markdown file and
/// checks each fenced code block against the source file it cites.
enum ReadmeSnippets {
    /// One `<!-- doc-snippet -->` block: the fenced code it wraps, and the
    /// source-file path (relative to the package root) it claims to excerpt.
    struct Snippet {
        /// The source-file path, relative to the package root, the code claims
        /// to excerpt.
        let sourcePath: String
        /// The fenced code the block wraps.
        let code: String
    }

    /// Extracts every well-formed `doc-snippet` block from `readme`, in
    /// document order.
    ///
    /// A block is: a `<!-- doc-snippet source="PATH" -->` line, a fenced code
    /// block (` ``` ` … ` ``` `), then a `<!-- /doc-snippet -->` line.
    /// Malformed blocks — a marker with no following fence, or a fence with no
    /// following `<!-- /doc-snippet -->` closing marker — are skipped.
    static func parse(_ readme: String) throws -> [Snippet] {
        let lines = readme.components(separatedBy: "\n")
        var snippets: [Snippet] = []
        var index = 0

        while index < lines.count {
            guard let sourcePath = sourcePath(fromMarkerLine: lines[index]) else {
                index += 1
                continue
            }
            index += 1  // past the marker line
            guard index < lines.count, lines[index].hasPrefix("```") else {
                index += 1
                continue
            }
            index += 1

            var codeLines: [String] = []
            while index < lines.count, lines[index] != "```" {
                codeLines.append(lines[index])
                index += 1
            }
            index += 1  // past the closing fence
            guard index < lines.count, lines[index] == "<!-- /doc-snippet -->" else {
                continue
            }
            index += 1  // past the closing marker

            snippets.append(Snippet(sourcePath: sourcePath, code: codeLines.joined(separator: "\n")))
        }
        return snippets
    }

    /// The `source="..."` value from a `<!-- doc-snippet source="..." -->` line,
    /// or `nil` if `line` isn't one.
    private static func sourcePath(fromMarkerLine line: String) -> String? {
        let prefix = "<!-- doc-snippet source=\""
        guard line.hasPrefix(prefix), let closingQuote = line.range(of: "\" -->") else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        return String(line[start..<closingQuote.lowerBound])
    }

    /// Whether `snippet`'s lines, each trimmed of leading/trailing whitespace,
    /// appear as a contiguous, in-order run somewhere in `sourceLines` (also
    /// trimmed).
    ///
    /// Comparing trimmed lines — rather than requiring byte-identical text —
    /// lets the README re-indent a snippet for readability (e.g. dedenting code
    /// excerpted from inside a nested type) while still requiring it to be a
    /// genuine, ordered, contiguous excerpt of the real file, not lines
    /// cherry-picked from unrelated places or invented outright.
    static func isContiguousExcerpt(_ snippet: String, of sourceLines: [String]) -> Bool {
        let needle = snippet.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let haystack = sourceLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }

        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}
