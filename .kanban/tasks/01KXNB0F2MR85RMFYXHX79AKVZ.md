---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Backfill split-lost tests: command_id parity + missing kill id corrective'
---
## What

When plan §9 task 5 ("Five operations + ShellTool.make()") was split into four board tasks, two of its specified tests were never inherited by any split task:

1. **Explicit camelCase-vs-snake_case parity for `command_id`.** The trashed task required a parity test proving snake_case and camelCase payload keys resolve identically "for at least `execute command` and `get lines`". Only the `working_directory` parity test survived (`snakeCaseAndCamelCaseWorkingDirectoryResolveIdentically`, Tests/ShellToolTests/ExecuteCommandTests.swift). Existing history-op tests use only the snake_case spelling (`"command_id"` in Tests/ShellToolTests/HistoryOpsTests.swift and Tests/ShellToolTests/FusionTests.swift) — nothing asserts both spellings give the same result, so a resolver-normalization regression for this key would go unnoticed.
2. **Missing-required-`id` corrective for `kill process`.** The trashed task listed corrective-message tests for every missing required param (`command`, `id`, `pattern`, `commandId`). Tests/ShellToolTests/ProcessOpsTests.swift covers unknown id and already-finished id, but not a payload with `"op": "kill process"` and **no `id` at all**.

Add, following the existing dispatch-test style (drive the fused tool from `ShellTool.make`, build payloads with `GeneratedContent(properties:)`):

- [ ] In Tests/ShellToolTests/HistoryOpsTests.swift: a parity test for `get lines` — same stored command, one call with `"command_id"`, one with `"commandId"`, assert identical `LineRange` results (mirror the `working_directory` test's shape)
- [ ] In Tests/ShellToolTests/HistoryOpsTests.swift: the same parity assertion for `grep history` with the command-id filter (use a pattern that matches output text)
- [ ] In Tests/ShellToolTests/ProcessOpsTests.swift: `kill process` with no `id` key returns a corrective message naming the missing parameter, and does not throw

Test-only change; no production code expected. If any new test fails, that is a real resolver/dispatch bug — report it rather than adjusting the assertion.

## Acceptance Criteria
- [ ] Both spellings of the command-id key produce byte-identical (or structurally equal) results for `get lines` and `grep history`
- [ ] A `kill process` payload without `id` yields a corrective message (not a thrown error, not a crash) that names `id`
- [ ] `swift test` passes with the three new tests included

## Tests
- [ ] The three tests above (this task IS the tests) in Tests/ShellToolTests/HistoryOpsTests.swift and Tests/ShellToolTests/ProcessOpsTests.swift
- [ ] `swift test` — full suite green, 145+ tests, 0 failures

## Workflow
- Use `/tdd` — these tests pin existing behavior; write each, watch it pass, and treat any failure as a genuine finding to surface.