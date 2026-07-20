---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxzqm39b3qz30gd1zakm9tq3
  text: |-
    Implementation complete: added `FoundationModelsExtras` dependency to `Package.swift` (both `ShellTool` and `ShellToolTests` targets — the test target needs it directly since `ShellPolicyTests.swift` imports it to construct a `DotfolderStack` for the XDG-override test), rewired `ShellPolicy.defaultUserConfigURL()`/`defaultProjectConfigURL()` through `DotfolderStack(name: "shell", ...)`, updated header/doc comments to describe the XDG-based user layer, and added 3 new tests (`defaultUserConfigURLDerivesFromXDGConfigHome`, `xdgConfigHomeOverrideIsHonoredByTheUnderlyingStack`, `defaultProjectConfigURLResolvesGitRootShellFolder`).

    Verification: `swift build` exit 0, `swift test` 154/154 passed in 16 suites (incl. DocCoverageTests). Note: sourcekit-lsp's live diagnostics still show a stale "No such module 'FoundationModelsExtras'" error — this is a stale LSP index from before the dependency was resolved, not a real compile error (confirmed by clean `swift build`/`swift test` at the command line).

    Spawned double-check agent for adversarial review; awaiting verdict before final handoff.
  timestamp: 2026-07-20T12:22:13.035258+00:00
- actor: claude-code
  id: 01kxzqsw19dvgxyxa5qb6tjh7n
  text: |-
    Adversarial double-check verdict: REVISE, with two findings.

    1. **Fixed**: `plan.md` had two stale mentions of the pre-XDG user-layer path (`~/.shell/config.yaml`), in the §2 security bullet and the §8 "Security policy" section. Updated both to `~/.config/shell/config.yaml` (XDG, via `FoundationModelsExtras`'s `DotfolderStack`), consistent with the `ShellPolicy.swift` header comment.

    2. **Not fixed, justified**: five test files (`CLIConvergenceTests.swift`, `HistoryOpsTests.swift`, `ExecuteCommandTests.swift`, `ProcessOpsTests.swift`, `FusionTests.swift`) have an informal doc comment fragment "no `~/.shell` or project overlay" describing their builtin-only test setup. This is stale in the same sense but purely cosmetic (doesn't affect behavior or correctness), and the task's deliberate constraints explicitly state these files "should not need modification." Editing them for a comment wording nit would violate that scope boundary for no functional gain. Leaving as-is.

    Re-verified after the `plan.md` fix: `swift build` exit 0, `swift test` 154/154 passed in 16 suites (incl. DocCoverageTests). All acceptance criteria and subtasks are complete. Leaving task in `doing` for `/review`.
  timestamp: 2026-07-20T12:25:22.217426+00:00
- actor: claude-code
  id: 01kxzwm5tkcybh5zp3gxatkzpb
  text: '/finish picking up this task (it was the only actionable item on the board — no ready todo or review tasks). Implement is already green from the prior session; continuing the pipeline: test → commit checkpoint → review.'
  timestamp: 2026-07-20T13:49:38.515403+00:00
- actor: claude-code
  id: 01kxzwt4rkec2gk2k7p28k8nsy
  text: 'Test step (via /finish): fresh from-scratch `swift test` (after `swift package clean`) — 154/154 tests passed in 16 suites, exit 0. Nothing needed fixing. Proceeding to commit checkpoint.'
  timestamp: 2026-07-20T13:52:54.035564+00:00
position_column: doing
position_ordinal: '80'
title: Adopt FoundationModelsExtras DotfolderStack for ShellPolicy config path resolution
---
## What

Replace `ShellPolicy`'s hand-rolled dotfolder path resolution with the family-shared `DotfolderStack` from the `FoundationModelsExtras` package (`/Users/wballard/github/swissarmyhammer/FoundationModelsExtras`, `Sources/FoundationModelsExtras/DotfolderStack.swift`, currently at `d8165ba`).

**Behavior change from `d8165ba` ("switch user layer to XDG config directory"):** `DotfolderStack`'s `.user` layer no longer roots at `~/.<name>/`. It now roots at `$XDG_CONFIG_HOME/<name>/` (bare name, no leading dot), falling back to `~/.config/<name>/` when `XDG_CONFIG_HOME` is unset or not an absolute path. This is a real, user-visible change: `ShellPolicy`'s user-layer default moves from `~/.shell/config.yaml` to `~/.config/shell/config.yaml` (or `$XDG_CONFIG_HOME/shell/config.yaml`). The `.project` layer is untouched — still `<workingDirectory>/.shell/`.

**Files to modify:**
- `Package.swift` — add the package dependency, mirroring the existing `FoundationModelsOperationTool` entry style: `.package(url: "git@github.com:swissarmyhammer/FoundationModelsExtras.git", branch: "main")`, and add `.product(name: "FoundationModelsExtras", package: "FoundationModelsExtras")` to the `ShellTool` target.
- `Sources/ShellTool/ShellPolicy.swift` — rewire the default-path helpers to derive from a `DotfolderStack(name: "shell", ...)`:
  - Delete the private `shellConfigFileName` constant and the hand-rolled path composition in `defaultUserConfigURL()` / `defaultProjectConfigURL()`.
  - Build a `DotfolderStack(name: "shell", workingDirectory: <git root, falling back to cwd>, defaultsDirectory: nil)`. Derive the user-layer default URL from the stack's `.user` layer root + `"config.yaml"` (now XDG-based — `~/.config/shell/config.yaml` by default, respecting `XDG_CONFIG_HOME`), and the project-layer default URL from the `.project` layer root + `"config.yaml"` (still `nil` when not inside a git working tree — keep the existing git-root walk, pass its result as the stack's `workingDirectory`).
  - Update the file-header comment (`ShellPolicy.swift:1-25`, the "Three layers... 2. User — `~/.shell/config.yaml`" description) and the `defaultUserConfigURL()` doc comment to describe the XDG location, not `~/.shell/config.yaml`.
- `Tests/ShellToolTests/ShellPolicyTests.swift` — add coverage for the new resolution (see Tests).

**Deliberate constraints (preserve where the underlying stack allows):**
- Keep the public `init(userConfigURL:projectConfigURL:warn:)` signature unchanged — it is the injection seam used by ~20 call sites across 6 test files (`ShellPolicyTests`, `CLIConvergenceTests`, `HistoryOpsTests`, `ExecuteCommandTests`, `ProcessOpsTests`, `FusionTests`); none of those should need edits.
- Keep the embedded `builtinYAML` as the lowest layer with `defaultsDirectory: nil` — `DotfolderStack.Source.defaults` requires a real on-disk directory ("never compiled-in content"), and the compiled-in catastrophic-mistake deny list must stay unconditionally present.
- Keep merge semantics in `loadConfig()` untouched — `DotfolderStack` only locates files; key-level merging is documented as a consumer concern.
- Project layer continues to root at the nearest enclosing git working tree (passed as the stack's `workingDirectory`), matching current `defaultProjectConfigURL()` behavior — this layer is unaffected by the XDG change.
- Do **not** add a migration/fallback that also checks the old `~/.shell/config.yaml` location — this task adopts the family convention as-is. If a migration path is wanted, that is separate follow-up work; flag it to the user rather than scope-creeping this card.

**Subtasks:**
- [x] Add the `FoundationModelsExtras` dependency to `Package.swift` and confirm `swift build` resolves it
- [x] Rewire `defaultUserConfigURL()` / `defaultProjectConfigURL()` through `DotfolderStack(name: "shell", ...)`
- [x] Update `ShellPolicy.swift` header/doc comments to describe the XDG-based user layer (keep doc coverage green)
- [x] Add `ShellPolicyTests` cases for stack-derived defaults, including an `XDG_CONFIG_HOME` override case
- [x] Run the full suite and the `DocCoverageTests` gate

## Acceptance Criteria

- [x] `ShellTool` links `FoundationModelsExtras` and `ShellPolicy` contains no hand-rolled `".shell/config.yaml"` string composition for the user layer (the literal `shellConfigFileName` constant is gone; paths come from `DotfolderStack` layer roots)
- [x] `ShellPolicy.defaultUserConfigURL()` resolves to `~/.config/shell/config.yaml` when `XDG_CONFIG_HOME` is unset, and to `$XDG_CONFIG_HOME/shell/config.yaml` when it is set to an absolute path — matching `DotfolderStack`'s documented XDG resolution
- [x] `ShellPolicy.defaultProjectConfigURL()` still resolves to `{git_root}/.shell/config.yaml` (or `nil` outside a git tree) — unchanged, since the project layer was not affected by the XDG change
- [x] Public API of `ShellPolicy` is unchanged: `init(userConfigURL:projectConfigURL:warn:)`, both default-path helpers keep their signatures, and no existing test file other than `ShellPolicyTests.swift` needs modification
- [x] The embedded builtin deny list remains in effect with no overlay files present (existing `missingConfigFilesLeaveBuiltinRulesInEffect` test still passes)
- [x] `swift test` passes, including `DocCoverageTests` (any new/changed `public` declarations are documented)

## Tests

- [x] In `Tests/ShellToolTests/ShellPolicyTests.swift`: add `defaultUserConfigURLDerivesFromXDGConfigHome` asserting `ShellPolicy.defaultUserConfigURL()` equals `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/shell/config.yaml")` when `XDG_CONFIG_HOME` is not set in the environment passed to the stack
- [x] In `Tests/ShellToolTests/ShellPolicyTests.swift`: add a case proving an `XDG_CONFIG_HOME` override is honored (construct the underlying `DotfolderStack` directly with a fake environment dictionary, since `ShellPolicy`'s own `init` takes no `environment:` parameter — assert the `.user` layer root equals `<XDG_CONFIG_HOME>/shell`)
- [x] In `Tests/ShellToolTests/ShellPolicyTests.swift`: add `defaultProjectConfigURLResolvesGitRootShellFolder` asserting that (running inside this repo) `ShellPolicy.defaultProjectConfigURL()` ends with `.shell/config.yaml` and its directory contains a `.git` entry
- [x] Full regression: `swift test` from the package root exits 0 with all existing `ShellPolicyTests` (stacking, permit/deny, settings precedence) unchanged and passing

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.