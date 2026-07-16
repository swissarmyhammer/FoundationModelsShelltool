import Foundation
import Testing

/// Verifies that the five "departures discovered during implementation" entries
/// (8–12) in the repo root's `DESIGN_NOTES.md` are present, so a shipped
/// behavior that departs from the plan can't silently drop out of the changelog.
///
/// A presence test in the spirit of `ReadmeSnippetTests`: it reads
/// `DESIGN_NOTES.md` from the package root (via the shared
/// `PackageRootValidation.packageRoot()` helper, rather than re-deriving the
/// root) and asserts one distinctive phrase per entry. It deliberately does not
/// pin the full prose — only the load-bearing phrase for each departure — so the
/// entries stay editable while still failing the moment one is removed.
@Suite("DESIGN_NOTES departures presence")
struct DesignNotesTests {
    /// One distinctive phrase per new departure entry (8–12); each must appear
    /// verbatim in `DESIGN_NOTES.md`.
    private static let requiredPhrases = [
        "Batch-at-exit",  // 8. batch-at-exit log append
        "races stream EOF",  // 9. post-stream group-kill / timeout races EOF
        "Audit logging",  // 10. audit logging not ported
        "preferredDirectory",  // 11. public API is ShellTool.make(preferredDirectory:)
        "non-optional `Int`",  // 12. ExecuteResult.exitCode is non-optional Int
    ]

    @Test("each departure entry (8–12) is present in DESIGN_NOTES.md", arguments: requiredPhrases)
    func departureEntryIsPresent(phrase: String) throws {
        let notes = try designNotes()
        #expect(
            notes.contains(phrase),
            Comment(
                rawValue:
                    "DESIGN_NOTES.md is missing the distinctive phrase '\(phrase)' for a departure entry")
        )
    }

    /// The contents of the package root's `DESIGN_NOTES.md`.
    private func designNotes() throws -> String {
        let url = PackageRootValidation.packageRoot().appendingPathComponent("DESIGN_NOTES.md")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
