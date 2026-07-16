import Foundation

/// Shared path-containment guard for tests that resolve a relative path against
/// the package root and must reject paths that escape it via `..` or similar.
///
/// Used by both `DocCoverageTests` (scanning `Sources/ShellTool`) and
/// `ReadmeSnippetTests` (resolving README `doc-snippet` source citations). The
/// two call sites throw different error types, so the error is produced by a
/// caller-supplied closure rather than fixed here. Mirrors the upstream
/// package's `TestSupport.PackageRootValidation`, kept internal to this single
/// test target rather than split into a separate `TestSupport` module.
enum PackageRootValidation {
    /// Guards against `url` (resolved from a relative path via `..` or similar)
    /// falling outside `root`.
    ///
    /// - Parameters:
    ///   - url: The resolved URL to check.
    ///   - root: The package root URL `url` must equal or be a descendant of.
    ///   - onEscape: Produces the error to throw, given `url`'s standardized
    ///     path, when `url` resolves outside `root`.
    /// - Throws: The error `onEscape` produces if `url`'s standardized path
    ///   isn't `root`'s standardized path or a descendant of it.
    static func requireWithinPackageRoot<E: Error>(
        _ url: URL,
        root: URL,
        throwing onEscape: (String) -> E
    ) throws {
        let standardizedURL = url.standardizedFileURL.path
        let standardizedRoot = root.standardizedFileURL.path
        guard standardizedURL == standardizedRoot || standardizedURL.hasPrefix(standardizedRoot + "/") else {
            throw onEscape(standardizedURL)
        }
    }
}
