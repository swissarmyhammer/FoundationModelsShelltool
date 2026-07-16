---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxnh1bd5henf69dbmkmk4kee
  text: 'Picked up by /finish (scoped-batch) after DESIGN_NOTES ^j6k9e27 landed done. LAST of the 3 follow-up tasks. Starting iteration 1: /implement. Test-only backfill of 3 split-lost tests: (1) get lines command_id camel/snake parity, (2) grep history command_id-filter parity, (3) kill process missing-`id` corrective (names `id`, no throw) — in HistoryOpsTests.swift + ProcessOpsTests.swift, following the fused-tool dispatch style. CAVEAT: these pin existing behavior — if any fails, it''s a real resolver/dispatch bug to SURFACE, not an assertion to soften. TDD per task.'
  timestamp: 2026-07-16T13:14:42.981395+00:00
- actor: claude-code
  id: 01kxnh5h2bd7181tvkqjsyxenw
  text: 'Research done. Moved to doing. Confirmed:\n- GetLines.commandID (required Int), GrepHistory.commandID (optional Int? filter, short -i), KillProcess.id (required Int, short -i). All resolve via the Operations framework''s OperationParam resolver, same path the surviving working_directory parity test exercises.\n- Missing-required corrective comes from OperationError.missingRequired -> \"Missing required parameter(s): <names>.\" (.build/checkouts/FoundationModelsOperationTool/Sources/Operations/OperationError.swift). OperationTool returns it as a string before execute(in:) runs (no throw). KillProcess property name is `id`, so the message names `id`.\n\nDesign note for grep-history parity: grep''s commandID filter is OPTIONAL, so a single-command setup would give identical totals with or without the filter and wouldn''t detect a dropped filter key. Using TWO commands with different match counts (2 vs 3) and filtering to command 1 -> a resolved filter yields total:2 scoped, a dropped filter would scan both (total:5), breaking the snake==camel equality. Stronger than a bare mirror.'
  timestamp: 2026-07-16T13:16:59.851956+00:00
- actor: claude-code
  id: 01kxnhfg9n0qejy1k8y6w0bpz8
  text: 'DONE (green, left in doing for /review). All 3 tests added and PASSED AS-EXPECTED — behavior confirmed, NO resolver/dispatch bug found:\n\n1. HistoryOpsTests.snakeCaseAndCamelCaseCommandIdResolveIdenticallyForGetLines — PASS. get lines with command_id:1 vs commandId:1 return byte-identical LineRange (commandId:1, 1: alpha, 3: gamma).\n2. HistoryOpsTests.snakeCaseAndCamelCaseCommandIdResolveIdenticallyForGrepHistory — PASS. Two commands (2 vs 3 MATCH lines); filter to command 1 gives total:2 (not 5) for both spellings; !commandId:2.\n3. ProcessOpsTests.killProcessWithNoIdKeyReturnsACorrectiveNamingTheMissingParameter — PASS. `kill process` with no id returns \"Missing required parameter(s): id.\" — a returned string (no throw, no crash), no linesCaptured.\n\nWHY they pass (root cause understood, not luck): the Operations framework''s OperationKeys.normalized strips `_`/`-` and lowercases, so command_id, commandId, commandID ALL normalize to \"commandid\" and hit one normalizedIndex lookup. No split-lost regression exists — the gap was purely missing coverage.\n\nDouble-check (adversarial) returned REVISE on ONE low-sev doc-comment inaccuracy: my original comments claimed the snake==camel EQUALITY is what catches a dropped key. It is not — both spellings normalize together, so a real regression breaks them in lockstep and equality still holds; the VALUE assertions (total:2/!commandId:2 for grep; the stored lines for get lines) are the discriminators. Reworded both doc comments to attribute correctly and describe equality as pinning non-divergence. Behavior/assertions unchanged.\n\nswift test: 151 tests in 16 suites, 0 failures, 0 warnings, exit 0. Full-suite run confirmed twice (before and after the comment reword).\n\nNote: sourcekit-lsp not installed in this env (get callgraph/blastradius unavailable), so research used targeted reads + grep; does not affect test-only outcome.'
  timestamp: 2026-07-16T13:22:26.741917+00:00
position_column: doing
position_ordinal: '80'
title: 'Backfill split-lost tests: command_id parity + missing kill id corrective'
---
## What

When plan §9 task 5 ("Five operations + ShellTool.make()") was split into four board tasks, two of its specified tests were never inherited by any split task:

1. **Explicit camelCase-vs-snake_case parity for `command_id`.** The trashed task required a parity test proving snake_case and camelCase payload keys resolve identically "for at least `execute command` and `get lines`". Only the `working_directory` parity test survived (`snakeCaseAndCamelCaseWorkingDirectoryResolveIdentically`, Tests/ShellToolTests/ExecuteCommandTests.swift). Existing history-op tests use only the snake_case spelling (`"command_id"` in Tests/ShellToolTests/HistoryOpsTests.swift and Tests/ShellToolTests/FusionTests.swift) — nothing asserts both spellings give the same result, so a resolver-normalization regression for this key would go unnoticed.
2. **Missing-required-`id` corrective for `kill process`.** The trashed task listed corrective-message tests for every missing required param (`command`, `id`, `pattern`, `commandId`). Tests/ShellToolTests/ProcessOpsTests.swift covers unknown id and already-finished id, but not a payload with `"op": "kill process"` and **no `id` at all**.

Add, following the existing dispatch-test style (drive the fused tool from `ShellTool.make`, build payloads with `GeneratedContent(properties:)`):

- [x] In Tests/ShellToolTests/HistoryOpsTests.swift: a parity test for `get lines` — same stored command, one call with `"command_id"`, one with `"commandId"`, assert identical `LineRange` results (mirror the `working_directory` test's shape)
- [x] In Tests/ShellToolTests/HistoryOpsTests.swift: the same parity assertion for `grep history` with the command-id filter (use a pattern that matches output text)
- [x] In Tests/ShellToolTests/ProcessOpsTests.swift: `kill process` with no `id` key returns a corrective message naming the missing parameter, and does not throw

Test-only change; no production code expected. If any new test fails, that is a real resolver/dispatch bug — report it rather than adjusting the assertion.

## Acceptance Criteria
- [x] Both spellings of the command-id key produce byte-identical (or structurally equal) results for `get lines` and `grep history`
- [x] A `kill process` payload without `id` yields a corrective message (not a thrown error, not a crash) that names `id`
- [x] `swift test` passes with the three new tests included

## Tests
- [x] The three tests above (this task IS the tests) in Tests/ShellToolTests/HistoryOpsTests.swift and Tests/ShellToolTests/ProcessOpsTests.swift
- [x] `swift test` — full suite green, 145+ tests, 0 failures

## Workflow
- Use `/tdd` — these tests pin existing behavior; write each, watch it pass, and treat any failure as a genuine finding to surface.