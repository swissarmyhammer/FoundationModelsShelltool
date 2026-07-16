import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Enforces the "Docs" task's "DocC comments on all public API" requirement:
/// every `public` declaration anywhere under `Sources/ShellTool` must have a
/// `///` doc comment directly attached to it (per the codebase's own
/// established convention — see e.g. `Sources/ShellTool/ShellPolicy.swift`).
///
/// Regression coverage for `DocCoverageScanner` itself lives in
/// `DocCoverageScannerTests.swift`, against synthetic fixtures; this test is the
/// integration check against the real source tree. Mirrors the upstream
/// `FoundationModelsOperationTool`'s `DocCoverageTests.swift`.
@Suite("Public API doc coverage")
struct DocCoverageTests {
    @Test("every public declaration in Sources/ShellTool has an attached doc comment")
    func shellToolSourceIsFullyDocumented() throws {
        let violations = try DocCoverageScanner.scan(directory: "Sources/ShellTool")
        #expect(violations.isEmpty, Comment(rawValue: "\n" + violations.map(\.description).joined(separator: "\n")))
    }

    @Test("scanning a directory that escapes the package root throws pathEscapesPackageRoot")
    func scanningADirectoryOutsideThePackageRootThrows() {
        #expect(throws: DocCoverageScanner.ScanError.self) {
            _ = try DocCoverageScanner.scan(directory: "../../../../../../etc")
        }
    }
}

/// Scans a directory tree of Swift source files for `public` declarations that
/// have no `///` doc comment directly attached to them.
///
/// "Directly attached" means the doc comment's last line is separated from the
/// declaration (or its leading attributes, e.g. `@Generable`) by exactly one
/// newline — no blank line in between — matching how this codebase's existing,
/// review-enforced doc comments are written throughout `Sources/ShellTool`.
enum DocCoverageScanner {
    /// One undocumented public declaration: where it is, and what it's called.
    struct Violation: CustomStringConvertible, Equatable {
        /// The source file's path, relative to the package root.
        let filePath: String

        /// The declaration's 1-based line number.
        let line: Int

        /// The declaration's name (or, for a `var`/`let` binding a tuple pattern
        /// or an enum case with several elements, its comma-joined names).
        let name: String

        var description: String {
            "\(filePath):\(line): '\(name)' is public but has no attached `///` doc comment"
        }
    }

    /// An error scanning a directory.
    enum ScanError: Error, CustomStringConvertible {
        /// `directory` (as passed to `scan(directory:)`) resolved to a path
        /// outside the package root — e.g. via a `..` component.
        case pathEscapesPackageRoot(String)

        var description: String {
            switch self {
            case .pathEscapesPackageRoot(let path):
                return "'\(path)' resolves outside the package root"
            }
        }
    }

    /// Scans every `.swift` file at or below `directory` (recursively, so the
    /// `Operations/` subdirectory is covered too) for undocumented `public`
    /// declarations.
    ///
    /// - Parameter directory: The directory to scan, relative to the package root.
    /// - Returns: Every violation found, in file-then-declaration order.
    /// - Throws: `ScanError.pathEscapesPackageRoot` if `directory` resolves
    ///   outside the package root (e.g. via `..`); otherwise if the resolved
    ///   directory cannot be listed, or a `.swift` file within it cannot be read
    ///   as UTF-8.
    static func scan(directory: String) throws -> [Violation] {
        let root = PackageRootValidation.packageRoot()
        let directoryURL = root.appendingPathComponent(directory)
        try PackageRootValidation.requireWithinPackageRoot(directoryURL, root: root) {
            ScanError.pathEscapesPackageRoot($0)
        }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL, includingPropertiesForKeys: nil)
        let files =
            (enumerator?.allObjects.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }

        var allViolations: [Violation] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            allViolations.append(contentsOf: violations(in: source, filePath: relativePath))
        }
        return allViolations
    }

    /// Parses `source` and returns every undocumented `public` declaration found
    /// in it, attributing each to `filePath`.
    static func violations(in source: String, filePath: String) -> [Violation] {
        let tree = Parser.parse(source: source)
        let visitor = DocCoverageVisitor(filePath: filePath, tree: tree)
        visitor.walk(tree)
        return visitor.violations
    }
}

/// Walks a parsed source file, recording every `public` declaration — and every
/// `case` inside a `public enum`, which inherits the enum's access level and
/// carries no modifier of its own — that has no doc comment directly attached to
/// it.
private final class DocCoverageVisitor: SyntaxVisitor {
    private(set) var violations: [DocCoverageScanner.Violation] = []
    private let filePath: String
    private let converter: SourceLocationConverter

    init(filePath: String, tree: SourceFileSyntax) {
        self.filePath = filePath
        self.converter = SourceLocationConverter(fileName: filePath, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: "init")
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: "subscript")
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: propertyNames(node))
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node, name: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        if isInsidePublicEnum(node), !hasAttachedDocComment(node.leadingTrivia) {
            record(node, name: caseNames(node))
        }
        return .visitChildren
    }

    /// Records a violation if `node` carries an explicit `public` modifier and
    /// has no doc comment directly attached to it.
    private func check(_ node: some SyntaxProtocol & WithModifiersSyntax, name: String) {
        guard node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }) else { return }
        guard !hasAttachedDocComment(node.leadingTrivia) else { return }
        record(node, name: name)
    }

    private func record(_ node: some SyntaxProtocol, name: String) {
        let line = node.startLocation(converter: converter).line
        violations.append(DocCoverageScanner.Violation(filePath: filePath, line: line, name: name))
    }

    /// Whether `trivia` ends in a doc comment directly attached to the following
    /// declaration: after any trailing indentation, exactly one newline, then
    /// (after any further indentation) a `///` or `/** */` comment — no blank
    /// line in between.
    private func hasAttachedDocComment(_ trivia: Trivia) -> Bool {
        var pieces = Array(trivia)
        dropTrailingHorizontalWhitespace(&pieces)
        guard case .newlines(1) = pieces.popLast() else { return false }
        dropTrailingHorizontalWhitespace(&pieces)
        switch pieces.last {
        case .docLineComment, .docBlockComment: return true
        default: return false
        }
    }

    /// Removes trailing `.spaces`/`.tabs` pieces (indentation) from `pieces`.
    private func dropTrailingHorizontalWhitespace(_ pieces: inout [TriviaPiece]) {
        while case .spaces = pieces.last { pieces.removeLast() }
        while case .tabs = pieces.last { pieces.removeLast() }
    }

    /// Whether `node`'s nearest enclosing type declaration is a `public enum`.
    private func isInsidePublicEnum(_ node: EnumCaseDeclSyntax) -> Bool {
        var current = node.parent
        while let candidate = current {
            if let enumDecl = candidate.as(EnumDeclSyntax.self) {
                return enumDecl.modifiers.contains { $0.name.tokenKind == .keyword(.public) }
            }
            current = candidate.parent
        }
        return false
    }

    /// The comma-joined names of every identifier `node` binds (ordinarily one,
    /// e.g. `public let name: String`).
    private func propertyNames(_ node: VariableDeclSyntax) -> String {
        node.bindings
            .compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
            .joined(separator: ", ")
    }

    /// The comma-joined names of every case `node` declares (ordinarily one,
    /// e.g. `case add(String)`).
    private func caseNames(_ node: EnumCaseDeclSyntax) -> String {
        node.elements.map(\.name.text).joined(separator: ", ")
    }
}
