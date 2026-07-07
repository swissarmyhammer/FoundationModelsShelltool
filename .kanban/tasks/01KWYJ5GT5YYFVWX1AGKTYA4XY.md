---
depends_on:
- 01KWYJ55X4ESPSXZ8AR2DFM3KB
position_column: todo
position_ordinal: '8780'
title: Docs
---
## What
Write `README.md` (declare → fuse → session → CLI, library-style, with a runnable example matching the `Examples/ShellDemo` code — upstream's doc-snippet-testing mechanism) and DocC comments on all public API in `Sources/ShellTool/`. Cross-reference plan §8's departures from the Rust design directly in the docs where relevant:

1. Typed JSON outputs instead of preformatted text blocks
2. No tolerant string-int parsing (guided generation + typed CLI make it unnecessary)
3. `grep history` `limit` defaults to 10, documented as 10 (not Rust's stale "50")
4. `max_line_length` (2000) not ported — unenforced in Rust, so dropped here
5. UUID session ids (Rust uses ULID) — opaque log namespace, no ordering property used
6. macOS-only (no Windows arms — the platform is fixed by FoundationModels + `sh` anyway)
7. Free upgrades from upstream absent in Rust `shell`: op/verb aliases, key-case normalization, corrective-message retry cap, `includesSchemaInInstructions`

## Acceptance Criteria
- [ ] `README.md` exists at repo root with a working, copy-pasteable example that compiles against the actual package
- [ ] Every public type/function in `Sources/ShellTool/` has a DocC doc comment
- [ ] All 7 departures from plan §8 are documented somewhere discoverable (README or DESIGN_NOTES.md, matching the sibling packages' convention)

## Tests
- [ ] A doc-snippet test (mirroring upstream's mechanism) that extracts the README's code example and asserts it matches or compiles against `Examples/ShellDemo` source
- [ ] `swift build` with strict doc-coverage checking (if the repo adopts the same `DocCoverageTests.swift`-style SwiftSyntax doc-coverage test as `FoundationModelsOperationTool`) passes with zero undocumented public declarations

## Workflow
- Use `/tdd` for the doc-snippet test; docs themselves are written directly, not test-driven.