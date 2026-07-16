---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxnfwjbb5etwtncwa7ev44vn
  text: 'Picked up by /finish (scoped-batch) after grep-fix ^aaprkw8 landed done. Starting iteration 1: /implement. Doc-only + one presence test: add DESIGN_NOTES.md entries 8–12 (batch-at-exit log append; post-stream group-kill races EOF; audit-logging not ported / builtin YAML differs from sah; public API is ShellTool.make(preferredDirectory:); ExecuteResult.exitCode non-optional Int), matching the §8 entry style; entry 8 cross-refs the KillProcess doc comment; entry 10 states the builtin YAML divergence. New DesignNotesTests.swift presence test; keep ReadmeSnippetTests + DocCoverageTests green. TDD per task.'
  timestamp: 2026-07-16T12:54:37.675103+00:00
- actor: claude-code
  id: 01kxng34h6k4rppsr63am78jfv
  text: 'Implementation landed. TDD: wrote Tests/ShellToolTests/DesignNotesTests.swift FIRST (presence test asserting one distinctive phrase per entry 8-12: "Batch-at-exit", "races stream EOF", "Audit logging", "preferredDirectory", "non-optional `Int`"), watched it fail RED (5 issues, phrases absent). Then added `## Departures discovered during implementation` section (entries 8-12) to DESIGN_NOTES.md matching the §8 entry style; entry 8 cross-refs the KillResult.linesCaptured doc comment in KillProcess.swift; entry 10 explicitly states the builtin YAML is no longer byte-identical to sah''s builtin/shell/config.yaml. Entries 1-7 and Further reading unchanged. Verified each entry''s claim against source (ShellRunner.swift defer killpg + collector.finish→appendLines; ShellPolicy.swift builtinYAML has no enable_audit_logging; ShellTool.make(preferredDirectory:); ExecuteResult.exitCode non-optional Int backfilled via record?.exitCode ?? outcome.exitCode). Test now GREEN. Full `swift test`: 148 tests / 16 suites pass, exit 0, 0 warnings, including ReadmeSnippetTests and DocCoverageTests. Reused shared PackageRootValidation.packageRoot() helper rather than duplicating.'
  timestamp: 2026-07-16T12:58:12.902475+00:00
- actor: claude-code
  id: 01kxnge71c64zv2tfhw435aepw
  text: 'Adversarial double-check returned REVISE (3 findings); all fixed. (1) Medium — entry 12 wrongly said a "killed OR timed-out" record stores exitCode nil. Verified against source: only the KILLED path stores nil (ShellState.killProcess → completeCommand(exitCode: nil)); the TIMEOUT path stores -1 directly (ShellRunner → completeIfRunning(status: .timedOut, exitCode: -1); CommandRecord.exitCode field doc says "-1 on timeout"). Reworded entry 12 to scope the nil+backfill to killed only and state timed-out already stores -1. (2) Low — the surviving ShellPolicy.swift builtinYAML doc comment still claimed "Kept byte-faithful", contradicting new entry 10. Reconciled that comment to say the deny list is verbatim but the embedded config is a faithful *subset* (numeric limits interpolated; enable_audit_logging + max_line_length dropped), cross-referencing DESIGN_NOTES entries 10 and 4. README has no doc-snippet citing ShellPolicy.swift, so ReadmeSnippetTests unaffected. (3) Nit — entry 9 now quotes `defer { _ = killpg(pid, SIGKILL) }` verbatim. Re-ran full suite after the source edit: 148 tests / 16 suites pass, exit 0, 0 build warnings, DocCoverageTests + ReadmeSnippetTests + ShellPolicyTests + DesignNotesTests all green.'
  timestamp: 2026-07-16T13:04:15.916077+00:00
- actor: claude-code
  id: 01kxnghm6bwndp8aft0xmgzx91
  text: 'really-done: PASS. Confirmatory adversarial double-check verified all three fixes correct against source with no regressions (entries 1-7 and Further reading untouched; all five presence-test phrases present verbatim). Final verification: `swift test` → 148 tests / 16 suites pass, exit 0, 0 build warnings. Work complete and green; leaving task in `doing` for /review.'
  timestamp: 2026-07-16T13:06:07.691129+00:00
position_column: done
position_ordinal: 8c80
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