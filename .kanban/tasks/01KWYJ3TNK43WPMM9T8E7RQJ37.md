---
comments:
- actor: claude-code
  id: 01kxk4nvcrchyw6qjz66zx37jj
  text: 'Picked up by /finish (scoped-batch, no scope). Starting iteration 1: /implement.'
  timestamp: 2026-07-15T15:00:14.360824+00:00
- actor: claude-code
  id: 01kxk6v58djnccfwq797jdj9pp
  text: |-
    Picked up. Research done against upstream `../swissarmyhammer/crates/swissarmyhammer-shell` (src/config.rs, src/security.rs) and `builtin/shell/config.yaml` (15 deny patterns; permit empty; settings max_command_length 262144, max_env_value_length 1024, enable_audit_logging true).

    Port design (ShellPolicy.swift):
    - Config types: PatternRule{pattern,reason}, ShellSettings{maxCommandLength,maxEnvValueLength,enableAuditLogging,enableValidation}, ShellSecurityConfig{permit,deny,settings}. Parsed via Yams from snake_case YAML; missing keys -> defaults. `enable_validation` added as a YAML scalar (default true) per task (upstream hardcodes it true in from_config).
    - Builtin embedded as a Swift string literal carrying sah's exact deny list.
    - loadConfig() reloads fresh each check: builtin -> user (~/.shell/config.yaml) -> project ({git_root}/.shell/config.yaml). Lists concatenate; settings = last layer wins (whole-struct replace, parity with serde default behavior). Missing/malformed layers skipped.
    - Evaluation: enable_validation gate -> length check -> permit short-circuit -> deny (returns corrective String) -> default allow. Never throws; returns String? corrective message.
    - check(environment:) validates name regex ^[A-Za-z_][A-Za-z0-9_]*$, value length, null/CR/LF; protected vars (PATH,HOME,...) warn-but-pass.
    - check(workingDirectory: String) checks raw string for "../" then existence. NOTE: URL(fileURLWithPath:) normalizes away ".." for relative paths, so the traversal check must run on the raw path string, not a URL — verified empirically.

    TDD RED anchor = table-driven deny test (per builtin pattern: exemplar blocked + near-miss allowed).
  timestamp: 2026-07-15T15:38:05.453098+00:00
- actor: claude-code
  id: 01kxk7sxnxdhaaznry1nm9x9gg
  text: |-
    Implementation landed. Sources/ShellTool/ShellPolicy.swift + Tests/ShellToolTests/ShellPolicyTests.swift.

    TDD: table-driven deny test written first, watched all 15 cases fail against a nil-returning stub (RED), then implemented to green. Added permit-short-circuit, enable_validation, layer scalar-override, layer list-concat, missing-config, fresh-reload-per-call, env (name/value/null/CRLF/protected), and workdir (exists/../) tests.

    swift test: 36 tests in 3 suites pass, no warnings.

    FORMATTER DEAD-END worth flagging: `swift format -i -r Sources Tests` reformats the whole repo from the committed 4-space house style to swift-format's default 2-space (there is no .swift-format config anywhere in the repo or parents). Running it produced ~1300 lines of churn on already-committed files (ShellState.swift, ShellStateTests.swift, ScaffoldTests.swift). I reverted that churn (git checkout on the committed files) and kept my two new files in the repo's 4-space style. If the project actually wants swift-format's 2-space, that is a separate repo-wide decision (add a .swift-format or reformat everything in its own commit) — not this task's scope.
  timestamp: 2026-07-15T15:54:53.501734+00:00
- actor: claude-code
  id: 01kxk7zk517xpm8zjvkmdymgts
  text: |-
    really-done: `swift test` green (36 tests / 3 suites, 0 failures, 0 warnings). Adversarial double-check verdict: PASS. It confirmed the embedded builtinYAML matches builtin/shell/config.yaml byte-for-byte (all 15 patterns + reasons + order), hand-verified every deny exemplar matches and every near-miss does not, and confirmed evaluation order (enable_validation gate -> length -> permit short-circuit -> deny -> allow) and merge semantics (lists concat, settings last-layer-wins) match security.rs/config.rs. Every acceptance criterion is covered by a passing test.

    Non-blocking parity notes (satisfy the task spec as written, no action needed): character-count vs Rust byte-count for length limits (identical for ASCII; task says "characters"); workdir rejects `../` only, not `..\` (task says "no ../ component"); enable_validation modeled as a YAML field (task lists it as a gate and a test exercises it via YAML); an invalid overlay regex is inert rather than discarding the whole stack (arguably safer; task does not constrain).

    Leaving task in `doing` for /review.
  timestamp: 2026-07-15T15:57:59.329364+00:00
- actor: claude-code
  id: 01kxk80cwsqss0ww1tpm5x023s
  text: 'Iteration 1: implementation landed green in `doing` (36 tests / 3 suites pass, 0 failures, 0 warnings per implementer). Running /test to verify, then /commit checkpoint, then /review. Note for reviewer: implementer flagged a swift-format caveat — no `.swift-format` config in repo; running the formatter reformats the whole codebase 4-space→2-space (~1300 lines churn), so new files were kept in the repo''s prevailing 4-space style.'
  timestamp: 2026-07-15T15:58:25.689845+00:00
depends_on:
- 01KWYJ2FNNZ1HD5TP11KVA4DTN
position_column: doing
position_ordinal: '8180'
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