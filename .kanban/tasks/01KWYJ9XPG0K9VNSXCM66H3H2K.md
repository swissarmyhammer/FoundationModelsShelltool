---
depends_on:
- 01KWYJ2X4G62CNVVCZZP15SXER
- 01KWYJ3DKZTTR3VYT7MFZTQ0G3
- 01KWYJ3TNK43WPMM9T8E7RQJ37
position_column: todo
position_ordinal: '8880'
title: ExecuteCommand op + ShellContext
---
## What
Define `ShellContext` (the shared bundle of `ShellState` actor + `ShellRunner` + `ShellPolicy`) in `Sources/ShellTool/ShellContext.swift`, and implement the `ExecuteCommand` `@Generable @Operation` in `Sources/ShellTool/Operations/ExecuteCommand.swift`:

- Op string `"execute command"`. Params: `command` (required), `timeout?` secs, `workingDirectory?`, `environment?` (JSON-string map — `@Generable` has no dictionary type; parse/validate as in Rust).
- Pipeline: `ShellPolicy` validation → `ShellRunner.run` → `ShellState` storage under a fresh `command_id` → `ExecuteResult` output struct: `commandId`, `status` (`completed`/`timed_out`/`killed`), `exitCode`, `lines` (total stored), `durationMs`, `output: [String]` formatted as `"{lineNumber}: {text}"` for the **last 32 lines**, and `outputNote?` carrying the "showing last 32 of N — use get lines" message, the truncation marker, or the binary placeholder note as appropriate.
- A denied command (per `ShellPolicy`) returns a corrective message, not a thrown error.

## Acceptance Criteria
- [ ] `execute command` dispatches through `AnyOperation` and runs a real command end-to-end via `ShellContext`
- [ ] Missing required `command` param produces a corrective message
- [ ] A denied command (per `ShellPolicy`) produces a corrective message
- [ ] `ExecuteResult.outputNote` appears only when total lines > 32; absent otherwise
- [ ] `ExecuteResult` JSON shape matches the field names above
- [ ] snake_case payload keys (`working_directory`) resolve identically to camelCase (`workingDirectory`)

## Tests
- [ ] `Tests/ShellToolTests/ExecuteCommandTests.swift`: dispatch test through `AnyOperation`
- [ ] Missing-required-param corrective-message test
- [ ] Denied-command corrective-message test
- [ ] Tail-note-appears-only-past-32-lines test
- [ ] `ExecuteResult` JSON-shape snapshot test
- [ ] snake_case/camelCase payload parity test

## Workflow
- Use `/tdd` — write the dispatch test first, then build `ShellContext` and the execute pipeline to go GREEN.