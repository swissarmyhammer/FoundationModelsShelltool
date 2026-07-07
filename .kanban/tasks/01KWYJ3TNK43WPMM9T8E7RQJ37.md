---
depends_on:
- 01KWYJ2FNNZ1HD5TP11KVA4DTN
position_column: todo
position_ordinal: '8380'
title: ShellPolicy (stacked config + validation)
---
## What
Port `swissarmyhammer-shell`'s security policy as `ShellPolicy` in `Sources/ShellTool/ShellPolicy.swift`, using Yams to parse a three-layer stacked YAML config:

1. Builtin — an embedded Swift string literal carrying sah's exact deny-list from `builtin/shell/config.yaml` (catastrophic-mistake guards: `rm -rf /`, `dd ... of=/dev/`, `sudo`, `curl | sh`, …; explicitly *not* a security boundary — shell metacharacters remain allowed).
2. `~/.shell/config.yaml` (user layer)
3. `{git_root}/.shell/config.yaml` (project layer)

Later layers win for scalar settings (e.g. `enable_validation`); deny/permit pattern lists concatenate across layers. **Reload fresh on every `execute command` call — no caching.**

Evaluation order: permit match → allow (short-circuit); deny match → return a corrective message carrying the human-readable reason (never throw); no match → allow. `enable_validation: false` disables command checks entirely.

Additional validation, all returned as corrective messages rather than thrown:
- Command length ≤ 256 KiB
- Env var names match `^[A-Za-z_][A-Za-z0-9_]*$`; values ≤ 1024 chars, no null byte, no CR/LF
- Protected-var overrides (`PATH`, `HOME`, …) log a warning but are still allowed to pass
- Working directory must exist and must not contain a `../` path component

## Acceptance Criteria
- [ ] Every builtin deny pattern blocks its literal exemplar command
- [ ] A close-but-different command that merely resembles a deny pattern is allowed (no over-matching)
- [ ] A permit-list match short-circuits a would-be deny match
- [ ] `enable_validation: false` disables all command checks
- [ ] User layer (`~/.shell/config.yaml`) and project layer (`{git_root}/.shell/config.yaml`) both load, with later layers overriding scalar settings and concatenating list settings
- [ ] Config is reloaded (not cached) on each policy check within a test that mutates the file between calls
- [ ] Env var name regex, length limit, and null/CRLF checks all reject correctly
- [ ] `../` in a working directory is rejected; a normal existing directory passes
- [ ] Missing config files at any layer are not an error — policy still loads with builtin-only rules

## Tests
- [ ] `Tests/ShellToolTests/ShellPolicyTests.swift`: table-driven test iterating every builtin deny pattern (exemplar blocked, near-miss allowed)
- [ ] Permit-short-circuits-deny test
- [ ] Layer override test (scalar) and layer concatenation test (lists)
- [ ] Env name/value/protected-var test cases
- [ ] `../` rejection test
- [ ] Missing-config-files-are-fine test
- [ ] Fresh-reload-per-call test (edit config between two calls, assert the second call sees the edit)

## Workflow
- Use `/tdd` — the table-driven deny-list test is the natural RED-first anchor; build the stacked loader out from there.