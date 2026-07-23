import Foundation
import Testing

/// Verifies that the eight "departures discovered during implementation"
/// entries (8–15) in the repo root's `DESIGN_NOTES.md` are present, so a
/// shipped behavior that departs from the plan can't silently drop out of the
/// changelog.
///
/// A presence test in the spirit of `ReadmeSnippetTests`: it reads
/// `DESIGN_NOTES.md` from the package root (via the shared
/// `PackageRootValidation.packageRoot()` helper, rather than re-deriving the
/// root) and asserts one distinctive phrase per entry. It deliberately does not
/// pin the full prose — only the load-bearing phrase for each departure — so the
/// entries stay editable while still failing the moment one is removed.
///
/// Entries 8 and 12 were themselves superseded by the soft-deadline detach
/// work (kanban task `01KY5PDG4B3WH44FR1ZYCJKMWJ` / `ycjkmwj`): their pins were
/// moved off the original, now-historical wording and onto the superseding
/// paragraph, so the test fails if the *current* behavior's description ever
/// regresses — not just if the entry is deleted outright. Entries 13–15 are
/// new, one per behavior the detach work introduced.
@Suite("DESIGN_NOTES departures presence")
struct DesignNotesTests {
    /// One distinctive phrase per departure entry (8–15); each must appear
    /// verbatim in `DESIGN_NOTES.md`.
    private static let requiredPhrases = [
        "arrival-order interleaving",  // 8. batch-at-exit log append (superseded) — streaming ordering contract
        "races stream EOF",  // 9. post-stream group-kill / timeout races EOF
        "Audit logging",  // 10. audit logging not ported
        "preferredDirectory",  // 11. public API is ShellTool.make(preferredDirectory:)
        "omitted while `running`",  // 12. ExecuteResult.exitCode is Int? again (superseded)
        "Two clocks",  // 13. timeout bounds the child, waitSeconds bounds the tool call
        "`commandID` handle",  // 14. execute command can return running — divergence from Rust blocking semantics
        "detaches rather than kills",  // 15. cancellation during the wait window
    ]

    @Test("each departure entry (8–15) is present in DESIGN_NOTES.md", arguments: requiredPhrases)
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
