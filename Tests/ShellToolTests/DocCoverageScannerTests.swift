import Testing

/// Unit coverage for `DocCoverageScanner.violations(in:filePath:)` against
/// synthetic fixtures, independent of the real source tree — proves the scanner
/// itself catches every declaration kind `DocCoverageTests` relies on it to
/// check, and doesn't false-positive on already-documented or non-public code.
///
/// Mirrors the upstream `FoundationModelsOperationTool`'s
/// `DocCoverageScannerTests.swift`.
@Suite("DocCoverageScanner")
struct DocCoverageScannerTests {
    @Test("a documented public struct has no violations")
    func documentedPublicStructHasNoViolations() {
        let source = """
            /// A documented type.
            public struct Foo {
                /// A documented property.
                public let bar: Int
            }
            """
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }

    @Test("an undocumented public struct is a violation")
    func undocumentedPublicStructIsAViolation() {
        let source = "public struct Foo {}"
        let violations = DocCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations == [DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 1, name: "Foo")])
    }

    @Test("a doc comment separated by a blank line does not count as attached")
    func docCommentSeparatedByBlankLineIsNotAttached() {
        let source = """
            /// This talks about something else entirely.

            public struct Foo {}
            """
        let violations = DocCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations == [DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 3, name: "Foo")])
    }

    @Test("a doc comment attached through an attribute counts as attached")
    func docCommentAttachedThroughAnAttributeIsAttached() {
        let source = """
            /// Docs above the attribute.
            @available(*, deprecated)
            public struct Foo {}
            """
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }

    @Test("an internal declaration is never a violation")
    func internalDeclarationIsNeverAViolation() {
        let source = "struct Foo {}"
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }

    @Test("an undocumented public function is a violation")
    func undocumentedPublicFunctionIsAViolation() {
        let source = """
            public struct Foo {
                public func bar() {}
            }
            """
        let violations = DocCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations == [
            DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 1, name: "Foo"),
            DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 2, name: "bar"),
        ])
    }

    @Test("an undocumented case in a public enum is a violation despite carrying no modifier of its own")
    func undocumentedCaseInAPublicEnumIsAViolation() {
        let source = """
            /// A documented enum.
            public enum Foo {
                case bar
            }
            """
        let violations = DocCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations == [DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 3, name: "bar")])
    }

    @Test("a documented case in a public enum has no violations")
    func documentedCaseInAPublicEnumHasNoViolations() {
        let source = """
            /// A documented enum.
            public enum Foo {
                /// A documented case.
                case bar
            }
            """
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }

    @Test("an undocumented case in a non-public enum is not a violation")
    func undocumentedCaseInANonPublicEnumIsNotAViolation() {
        let source = """
            enum Foo {
                case bar
            }
            """
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }

    @Test("an undocumented public initializer is a violation")
    func undocumentedPublicInitializerIsAViolation() {
        let source = """
            public struct Foo {
                public init() {}
            }
            """
        let violations = DocCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations == [
            DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 1, name: "Foo"),
            DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 2, name: "init"),
        ])
    }

    @Test("an undocumented public actor is a violation")
    func undocumentedPublicActorIsAViolation() {
        // `ShellState` in this module is an `actor`; the gate must catch a
        // public one that is undocumented, not just structs/classes/enums.
        let source = "public actor Foo {}"
        let violations = DocCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations == [DocCoverageScanner.Violation(filePath: "Fixture.swift", line: 1, name: "Foo")])
    }

    @Test("a documented public actor has no violations")
    func documentedPublicActorHasNoViolations() {
        let source = """
            /// A documented actor.
            public actor Foo {}
            """
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }

    @Test("a public static let with an attached doc comment has no violations")
    func documentedPublicStaticLetHasNoViolations() {
        let source = """
            /// A documented type.
            public enum Foo {
                /// A documented constant.
                public static let bar = 1
            }
            """
        #expect(DocCoverageScanner.violations(in: source, filePath: "Fixture.swift").isEmpty)
    }
}
