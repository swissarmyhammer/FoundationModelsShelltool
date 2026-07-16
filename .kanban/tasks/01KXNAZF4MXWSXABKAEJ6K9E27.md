---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Record undocumented shipped departures in DESIGN_NOTES.md
---
## What

The plan-deviation audit found five shipped behaviors that depart from plan.md (§3/§4/§8) but are recorded nowhere in DESIGN_NOTES.md — violating the plan's own "deliberate departures are few and recorded" principle. Add a new numbered section to /Users/wballard/github/swissarmyhammer/FoundationModelsShelltool/DESIGN_NOTES.md (e.g. `## Departures discovered during implementation`, entries 8–12, same style as the existing §8 entries: what changed, why, pointer to the code) covering:

- [ ] **8. Batch-at-exit log append.** `ShellRunner` collects output and calls `ShellState.appendLines` once after both streams close (Sources/ShellTool/ShellRunner.swift, the `collector.finish()` → `appendLines` sequence), rather than streaming incrementally as the plan's "stream stdout+stderr into the log" and the Rust guard do. Consequence: `KillResult.linesCaptured` is `0` for a command killed mid-stream (already noted in a doc comment in Sources/ShellTool/Operations/KillProcess.swift — cross-reference it).
- [ ] **9. Post-stream group-kill / timeout races stream EOF.** The runner races the timeout timer against *stream EOF*, and an unconditional `defer { killpg(pid, SIGKILL) }` fires when the body exits — so a command that closes/redirects its stdout+stderr but keeps running (e.g. `exec >/dev/null 2>&1; sleep 100`) is SIGKILLed immediately and reported `completed` with exit `-1`, not `timed_out`. The Rust guard waits on the child itself. Record the rationale (no leaked daemons; the library reap needs the pipes closed).
- [ ] **10. Audit logging not ported.** `enable_audit_logging` was removed as dead code and the line stripped from the embedded builtin YAML in Sources/ShellTool/ShellPolicy.swift — so the builtin config is no longer byte-identical to sah's `builtin/shell/config.yaml`, narrowing the plan §5.6 "security layer ported whole" claim.
- [ ] **11. Public API is `ShellTool.make(preferredDirectory:)`, not plan §4's construction.** `ShellContext`/`ShellState` are module-internal; the plan §4 snippet (`ShellContext(state:policy:)`) cannot compile for an embedder. The public surface is the factory in Sources/ShellTool/ShellTool.swift.
- [ ] **12. `ExecuteResult.exitCode` is non-optional `Int`.** Plan §3 spelled `Int?`; the shipped type backfills `-1` for a killed/timed-out record whose stored code is nil (Sources/ShellTool/Operations/ExecuteCommand.swift).

Doc-only change plus one small test. If wording touches README-quoted snippets, keep `ReadmeSnippetTests` green.

## Acceptance Criteria
- [ ] DESIGN_NOTES.md contains five new numbered entries (8–12) matching the existing entry style, each naming the departure, the reason, and the code location
- [ ] Entry 8 cross-references the existing `KillProcess` doc comment; entry 10 explicitly states the builtin YAML differs from sah's `builtin/shell/config.yaml`
- [ ] Existing entries 1–7 and the "Further reading" section are unchanged

## Tests
- [ ] Add a presence test (new `Tests/ShellToolTests/DesignNotesTests.swift`, in the spirit of `ReadmeSnippetTests`): read DESIGN_NOTES.md from the package root and assert one distinctive heading/phrase per new entry exists (e.g. "Batch-at-exit", "Audit logging", "preferredDirectory"), so the entries can't silently regress
- [ ] `swift test` — full suite green, including `ReadmeSnippetTests` and `DocCoverageTests`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.