// `ShellPolicy` — the stacked-config shell security policy.
//
// A direct port of the Rust `swissarmyhammer-shell` crate (`src/config.rs` +
// `src/security.rs`). Three layers of YAML config stack with increasing
// precedence:
//
//   1. Builtin — the embedded `builtinYAML` below, carrying sah's exact
//      catastrophic-mistake deny list from `builtin/shell/config.yaml`.
//   2. User — `~/.shell/config.yaml`.
//   3. Project — `{git_root}/.shell/config.yaml`.
//
// Deny/permit pattern lists concatenate across layers; scalar settings take the
// value from the last layer that provides them. The config is reloaded fresh on
// every check — no caching — so edits to a config file take effect immediately,
// matching the Rust tool.
//
// These deny patterns are NOT a security boundary: the tool runs AI-generated
// commands and substring regexes are trivially evadable. Their only purpose is
// to be low-false-positive guards against catastrophic *mistakes* (`rm -rf /`,
// `dd ... of=/dev/`). Shell metacharacters remain allowed.
//
// Policy violations are **returned as human-readable corrective messages**
// (`String?`, `nil` == allowed) rather than thrown, so the caller can hand the
// message back to the model and let it rephrase within the same turn.

import Foundation
import Yams

/// A single permit or deny rule: a regex pattern plus the human-readable reason
/// it exists.
struct PatternRule: Sendable, Equatable, Decodable {
    /// Regex matched (unanchored) against the command string.
    let pattern: String
    /// Human-readable explanation surfaced when the rule fires.
    let reason: String
}

/// Validation settings controlling command/env limits and the master switch.
///
/// Missing YAML keys fall back to these defaults, so a partial `settings:` block
/// (or none at all) still yields a fully-populated struct — parity with the
/// Rust `#[serde(default)]` fields.
struct ShellSettings: Sendable, Equatable {
    /// Maximum command length in characters (256 KiB by default).
    var maxCommandLength: Int
    /// Maximum environment-variable value length in characters.
    var maxEnvValueLength: Int
    /// Whether command audit logging is enabled (carried for parity; the log
    /// itself lives in `ShellState`).
    var enableAuditLogging: Bool
    /// Master switch for command validation. When `false`, `check(command:)`
    /// short-circuits to "allowed" and runs no permit/deny/length checks.
    var enableValidation: Bool

    /// The in-code defaults, used for any setting a config layer omits.
    static let `default` = ShellSettings(
        maxCommandLength: 262_144,
        maxEnvValueLength: 1024,
        enableAuditLogging: true,
        enableValidation: true)
}

extension ShellSettings: Decodable {
    enum CodingKeys: String, CodingKey {
        case maxCommandLength = "max_command_length"
        case maxEnvValueLength = "max_env_value_length"
        case enableAuditLogging = "enable_audit_logging"
        case enableValidation = "enable_validation"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ShellSettings.default
        maxCommandLength =
            try container.decodeIfPresent(Int.self, forKey: .maxCommandLength)
            ?? fallback.maxCommandLength
        maxEnvValueLength =
            try container.decodeIfPresent(Int.self, forKey: .maxEnvValueLength)
            ?? fallback.maxEnvValueLength
        enableAuditLogging =
            try container.decodeIfPresent(Bool.self, forKey: .enableAuditLogging)
            ?? fallback.enableAuditLogging
        enableValidation =
            try container.decodeIfPresent(Bool.self, forKey: .enableValidation)
            ?? fallback.enableValidation
    }
}

/// A parsed shell security config: permit patterns (checked first, short-circuit
/// allow), deny patterns (checked second, block if matched), and settings.
struct ShellSecurityConfig: Sendable, Equatable {
    /// Patterns that explicitly allow a command, evaluated before deny patterns.
    var permit: [PatternRule]
    /// Patterns that block a command, evaluated after permit patterns.
    var deny: [PatternRule]
    /// Validation settings.
    var settings: ShellSettings

    /// An empty config with default settings — the fallback if even the builtin
    /// fails to parse.
    static let empty = ShellSecurityConfig(permit: [], deny: [], settings: .default)
}

extension ShellSecurityConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case permit
        case deny
        case settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        permit = try container.decodeIfPresent([PatternRule].self, forKey: .permit) ?? []
        deny = try container.decodeIfPresent([PatternRule].self, forKey: .deny) ?? []
        settings = try container.decodeIfPresent(ShellSettings.self, forKey: .settings) ?? .default
    }

    /// Merge another (later, higher-precedence) layer into this one:
    /// `permit`/`deny` lists concatenate; `settings` are taken wholesale from
    /// the later layer. This mirrors the Rust `merge`, including its documented
    /// caveat that the later layer's settings always win as a unit (a layer that
    /// omits a `settings:` block resets settings to their defaults).
    func merged(with other: ShellSecurityConfig) -> ShellSecurityConfig {
        ShellSecurityConfig(
            permit: permit + other.permit,
            deny: deny + other.deny,
            settings: other.settings)
    }
}

/// The stacked-config shell security policy.
///
/// Construct once and call the `check(...)` methods per command; each call
/// reloads the config from disk so overlay edits take effect immediately.
struct ShellPolicy: Sendable {
    /// The user-layer config file (`~/.shell/config.yaml` by default). A `nil`
    /// or missing file contributes nothing.
    let userConfigURL: URL?
    /// The project-layer config file (`{git_root}/.shell/config.yaml` by
    /// default). A `nil` or missing file contributes nothing.
    let projectConfigURL: URL?
    /// Sink for advisory warnings (e.g. a protected-variable override). Defaults
    /// to stderr; injectable so callers and tests can observe warnings.
    let warn: @Sendable (String) -> Void

    /// Create a policy over the given overlay files.
    ///
    /// - Parameters:
    ///   - userConfigURL: user-layer config; defaults to `~/.shell/config.yaml`.
    ///   - projectConfigURL: project-layer config; defaults to the git root's
    ///     `.shell/config.yaml`, or `nil` when not inside a git working tree.
    ///   - warn: advisory warning sink; defaults to writing to stderr.
    init(
        userConfigURL: URL? = ShellPolicy.defaultUserConfigURL(),
        projectConfigURL: URL? = ShellPolicy.defaultProjectConfigURL(),
        warn: @escaping @Sendable (String) -> Void = ShellPolicy.stderrWarn
    ) {
        self.userConfigURL = userConfigURL
        self.projectConfigURL = projectConfigURL
        self.warn = warn
    }

    // MARK: - Command validation

    /// Check a command against the freshly-loaded policy.
    ///
    /// Evaluation order: `enable_validation` gate → command-length limit →
    /// permit match (short-circuit allow) → deny match (block) → default allow.
    ///
    /// - Returns: `nil` if the command is allowed, otherwise a human-readable
    ///   corrective message carrying the reason it was blocked.
    func check(command: String) -> String? {
        let config = loadConfig()
        guard config.settings.enableValidation else { return nil }

        let length = command.count
        if length > config.settings.maxCommandLength {
            return
                "Command too long: \(length) characters exceeds limit of \(config.settings.maxCommandLength)"
        }

        for rule in config.permit where Self.matches(rule.pattern, command) {
            return nil
        }

        for rule in config.deny where Self.matches(rule.pattern, command) {
            return "Command blocked by shell policy: \(rule.reason)"
        }

        return nil
    }

    // MARK: - Environment validation

    /// Check an environment-variable map against the freshly-loaded policy.
    ///
    /// Each name must match `^[A-Za-z_][A-Za-z0-9_]*$`; each value must be within
    /// the configured length, contain no null byte, and no CR/LF. Overriding a
    /// protected variable (`PATH`, `HOME`, …) is allowed but emits a warning.
    ///
    /// - Returns: `nil` if every entry is valid, otherwise a corrective message
    ///   for the first offending entry.
    func check(environment: [String: String]) -> String? {
        let maxLength = loadConfig().settings.maxEnvValueLength

        for (name, value) in environment {
            if !Self.isValidEnvironmentVariableName(name) {
                return "Environment variable name invalid: \(name)"
            }
            if value.count > maxLength {
                return
                    "Environment variable \(name) has invalid value: value length \(value.count) exceeds maximum of \(maxLength) characters"
            }
            if value.contains("\0") {
                return "Environment variable \(name) has invalid value: null bytes are not allowed"
            }
            if value.contains("\n") || value.contains("\r") {
                return "Environment variable \(name) has invalid value: newlines are not allowed"
            }
            if Self.protectedVariables.contains(name) {
                warn("Modifying protected environment variable \(name)")
            }
        }
        return nil
    }

    // MARK: - Working-directory validation

    /// Check a working-directory path.
    ///
    /// The path must not contain a `../` traversal component and must name an
    /// existing directory. The traversal check runs on the raw path string
    /// (`URL(fileURLWithPath:)` normalizes `..` away for relative paths, so a
    /// URL-based check would miss it).
    ///
    /// - Returns: `nil` if the directory is acceptable, otherwise a corrective
    ///   message.
    func check(workingDirectory path: String) -> String? {
        if path.contains("../") {
            return "Working directory rejected: path contains a '..' traversal component: \(path)"
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return "Working directory does not exist: \(path)"
        }
        return nil
    }

    // MARK: - Config loading

    /// Load and merge the config stack fresh from disk (never cached).
    ///
    /// Starts from the embedded builtin, then merges the user and project layers
    /// in order. A layer whose file is missing or whose YAML fails to parse is
    /// silently skipped, so a broken overlay degrades to builtin-only rules.
    func loadConfig() -> ShellSecurityConfig {
        var config = Self.parse(Self.builtinYAML) ?? .empty
        for url in [userConfigURL, projectConfigURL] {
            guard let url,
                let text = try? String(contentsOf: url, encoding: .utf8),
                let layer = Self.parse(text)
            else { continue }
            config = config.merged(with: layer)
        }
        return config
    }

    /// Parse a YAML string into a config, or `nil` if it fails to parse.
    static func parse(_ yaml: String) -> ShellSecurityConfig? {
        try? YAMLDecoder().decode(ShellSecurityConfig.self, from: yaml)
    }

    // MARK: - Helpers

    /// Whether `pattern` (as a regex) matches anywhere in `command`. An
    /// uncompilable pattern never matches (a broken overlay rule is inert, not
    /// fatal).
    private static func matches(_ pattern: String, _ command: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return ((try? regex.firstMatch(in: command)) ?? nil) != nil
    }

    /// Whether `name` is a valid POSIX-ish env var name:
    /// `^[A-Za-z_][A-Za-z0-9_]*$`.
    private static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isASCII, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Environment variables that log a warning when overridden but are still
    /// allowed to pass (parity with the Rust `PROTECTED_VARS`).
    private static let protectedVariables: Set<String> = [
        "PATH",
        "LD_LIBRARY_PATH",
        "HOME",
        "USER",
        "SHELL",
        "SSH_AUTH_SOCK",
        "SUDO_USER",
        "SUDO_UID",
    ]

    /// The default warning sink: one line per warning to stderr.
    static let stderrWarn: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data("shell policy warning: \(message)\n".utf8))
    }

    /// The default user-layer config path, `~/.shell/config.yaml`.
    static func defaultUserConfigURL() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shell/config.yaml")
    }

    /// The default project-layer config path: the nearest enclosing git working
    /// tree's `.shell/config.yaml`, or `nil` when not inside one.
    static func defaultProjectConfigURL() -> URL? {
        var directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while true {
            let gitPath = directory.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitPath) {
                return directory.appendingPathComponent(".shell/config.yaml")
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// sah's exact builtin deny list, embedded at compile time as the
    /// lowest-precedence config layer. Kept byte-faithful to
    /// `builtin/shell/config.yaml` in the upstream `swissarmyhammer` repo.
    static let builtinYAML = #"""
        deny:
          # Catastrophic-mistake guards — destructive, low false-positive
          - pattern: 'rm\s+-rf\s+/'
            reason: "Destructive recursive delete from root"
          - pattern: 'rm\s+-rf\s+\*'
            reason: "Destructive recursive delete of all files"
          - pattern: 'dd\s+if=.*of=/dev/'
            reason: "Raw disk write via dd"
          - pattern: 'mkfs\s+'
            reason: "Filesystem creation command"
          - pattern: 'fdisk\s+'
            reason: "Disk partitioning command"
          - pattern: 'parted\s+'
            reason: "Disk partitioning command"
          - pattern: 'chmod\s+\+s\s+'
            reason: "Set SUID/SGID bit"

          # System-state mistake guards (override per-project via permit if needed)
          - pattern: 'shutdown\s+'
            reason: "System shutdown command"
          - pattern: 'reboot\s+'
            reason: "System reboot command"
          - pattern: 'sudo\s+'
            reason: "Privilege escalation"
          - pattern: 'systemctl\s+'
            reason: "System service management"
          - pattern: 'crontab\s+'
            reason: "Cron job modification"

          # Download-and-execute mistake guards (advisory, not a boundary)
          - pattern: 'wget.*http.*\|.*sh'
            reason: "Download and execute pattern"
          - pattern: 'curl.*http.*\|.*sh'
            reason: "Download and execute pattern"
          - pattern: 'nc\s+-l\s+'
            reason: "Netcat listener (reverse shell vector)"

        permit: []

        settings:
          max_command_length: 262144
          max_env_value_length: 1024
          enable_audit_logging: true
        """#
}
