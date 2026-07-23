// `OutputBuffer` — captures a command's stdout and stderr under a shared byte
// cap, truncating at line boundaries and detecting binary content.
//
// A direct behavioral port of the Rust `OutputBuffer`
// (`swissarmyhammer-tools` `mcp/tools/shell/infrastructure.rs`):
//
//   - One `maxSize` cap shared across stdout + stderr, tracked by the
//     cumulative `storedByteCount` (flushed-out lines plus whatever is still
//     resident) rather than the momentary `currentSize` — see below. Bytes
//     past the cap are dropped, but every byte is counted in
//     `totalBytesProcessed`.
//   - Truncation prefers a line boundary: the last `\n` in the fitting prefix,
//     else a UTF-8 code-point boundary, so a stored buffer is never cut through
//     a multi-byte scalar.
//   - Binary detection: a null byte within the first 8 KiB of any appended chunk
//     flags the whole capture binary; a binary stream renders as
//     `[Binary content: {n} bytes]` instead of its raw bytes.
//   - No ANSI stripping — output is stored raw (parity).
//
// Two ways to read the buffer back out, both exercised by `ShellRunner`:
//
//   - Batch: append everything, then read `stdoutLines`/`stderrLines` once at
//     the end. `ExecuteCommand`'s completed-command tail assembly relies on the
//     underlying `ShellState` log this eventually feeds, not on this API
//     directly.
//   - Incremental: `extractCompletedStdoutLines()`/`extractCompletedStderrLines()`
//     drain each stream's *completed* lines (up to the last `\n` seen so far)
//     as chunks arrive, leaving any trailing partial line buffered; `finish()`
//     seals the buffer at end-of-stream, flushing that trailing partial line
//     (or, if truncated/binary, a marker/placeholder line instead). This is
//     what lets `ShellRunner` stream a still-running command's output into
//     `ShellState` incrementally (see its file header).
//
// Because extraction can drain bytes back out of `stdoutData`/`stderrData`,
// the cap can no longer be enforced against `currentSize` (the momentarily
// resident byte count) — a flush would silently reopen room under the cap.
// `storedByteCount` is the monotonic, cumulative counter used instead: it only
// grows, by exactly the bytes actually accepted into storage (dropped bytes
// don't count, matching `truncated`), independent of what has since been
// extracted.
//
// Lines are derived exactly the way `ShellState` scans the log back (`\n`
// split, trailing `\r` dropped) so what is stored round-trips identically.

import Foundation

/// A size-capped capture buffer for one command's stdout and stderr.
struct OutputBuffer {
    /// The marker line `finish()` appends when output was truncated.
    static let truncationMarker = "[Output truncated - exceeded size limit]"
    /// Bytes of an appended chunk scanned for a null byte during binary sniffing.
    static let binaryDetectionSampleBytes = 8 * 1024
    /// The `\n` byte the shell log is split, truncated, and trimmed on.
    static let newlineByte = UInt8(ascii: "\n")

    /// The placeholder line rendered in place of a binary stream's raw bytes,
    /// mirroring `truncationMarker`'s role as the one home for its literal
    /// text. `byteCount` should always be the cumulative `storedByteCount`, so
    /// the same event reports the same count whether read live (`stdout`/
    /// `stderr`) or at `finish()`.
    static func binaryPlaceholder(byteCount: Int) -> String {
        "[Binary content: \(byteCount) bytes]"
    }

    /// Maximum total stored size in bytes, shared across stdout and stderr.
    let maxSize: Int

    private var stdoutData: [UInt8] = []
    private var stderrData: [UInt8] = []

    /// Whether any output was dropped to stay within `maxSize`.
    private(set) var truncated = false
    /// Whether binary content (a null byte) was seen in any appended chunk.
    private(set) var binaryDetected = false
    /// Count of all bytes seen, including bytes dropped past the cap.
    private(set) var totalBytesProcessed = 0
    /// Cumulative bytes actually accepted into storage — flushed out via
    /// `extractCompletedStdoutLines()`/`extractCompletedStderrLines()` plus
    /// whatever is still resident in `stdoutData`/`stderrData`. Monotonic: it
    /// only grows, and never shrinks when a flush drains the resident buffers.
    /// This — not `currentSize` — is what `append` checks against `maxSize`,
    /// so the cap keeps enforcing across incremental flushes (see the file
    /// header).
    private(set) var storedByteCount = 0

    /// Create a buffer with the given shared byte cap.
    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    /// Total bytes currently stored across both streams.
    var currentSize: Int { stdoutData.count + stderrData.count }

    /// Whether the stored size has reached the cap.
    var isAtLimit: Bool { currentSize >= maxSize }

    /// Append `data` to the stdout buffer, honoring the shared cap and binary
    /// detection. Returns the number of bytes actually stored.
    @discardableResult
    mutating func appendStdout(_ data: [UInt8]) -> Int {
        append(data, to: \.stdoutData)
    }

    /// Append `data` to the stderr buffer, honoring the shared cap and binary
    /// detection. Returns the number of bytes actually stored.
    @discardableResult
    mutating func appendStderr(_ data: [UInt8]) -> Int {
        append(data, to: \.stderrData)
    }

    /// The formatted stdout: the binary placeholder if binary, else lossy UTF-8.
    var stdout: String {
        Self.format(stdoutData, binaryDetected: binaryDetected, storedByteCount: storedByteCount)
    }

    /// The formatted stderr: the binary placeholder if binary, else lossy UTF-8.
    var stderr: String {
        Self.format(stderrData, binaryDetected: binaryDetected, storedByteCount: storedByteCount)
    }

    /// The stdout split into log lines the way `ShellState` reads them back.
    var stdoutLines: [String] { logLines(from: stdoutData) }

    /// The stderr split into log lines the way `ShellState` reads them back.
    var stderrLines: [String] { logLines(from: stderrData) }

    // MARK: - Appending

    private mutating func append(_ data: [UInt8], to keyPath: WritableKeyPath<OutputBuffer, [UInt8]>) -> Int {
        totalBytesProcessed += data.count

        if !binaryDetected, Self.isBinary(data) {
            binaryDetected = true
        }

        // Cumulative, not `currentSize`: a prior incremental flush may have
        // already drained bytes back out of the resident buffers, and the cap
        // must stay enforced against everything ever stored, not just what
        // happens to still be resident (see the file header).
        let available = max(0, maxSize - storedByteCount)
        if available == 0 {
            truncated = true
            return 0
        }

        let bytesToAppend = min(data.count, available)
        if bytesToAppend < data.count {
            truncated = true
        }

        let actual =
            bytesToAppend < data.count
            ? Self.safeTruncationPoint(data, upTo: bytesToAppend)
            : bytesToAppend

        self[keyPath: keyPath].append(contentsOf: data[0..<actual])
        storedByteCount += actual
        return actual
    }

    // MARK: - Incremental completed-line extraction

    /// Extract stdout bytes completed since the last extraction — everything
    /// up to and including the last `\n` currently buffered — as decoded log
    /// lines, leaving any trailing partial line (no closing `\n` yet) buffered
    /// for a later call or `finish()`. Yields nothing once `binaryDetected` has
    /// flipped: binary content stops flowing incrementally, and `finish()`
    /// emits the single placeholder line instead (see the file header).
    @discardableResult
    mutating func extractCompletedStdoutLines() -> [String] {
        extractCompletedLines(from: \.stdoutData)
    }

    /// The stderr counterpart of `extractCompletedStdoutLines()`.
    @discardableResult
    mutating func extractCompletedStderrLines() -> [String] {
        extractCompletedLines(from: \.stderrData)
    }

    /// Shared implementation behind `extractCompletedStdoutLines()`/
    /// `extractCompletedStderrLines()`: finds the last `\n` in the stream at
    /// `keyPath`, splits everything up to and including it into log lines, and
    /// leaves the remainder (the trailing partial line, if any) in place.
    /// Extraction only moves bytes out of the resident buffer — it never
    /// touches `storedByteCount`, so the cap stays enforced cumulatively.
    private mutating func extractCompletedLines(
        from keyPath: WritableKeyPath<OutputBuffer, [UInt8]>
    ) -> [String] {
        guard !binaryDetected else { return [] }
        let data = self[keyPath: keyPath]
        guard let cut = data.lastIndex(of: Self.newlineByte) else { return [] }

        let lines = Self.splitLogLines(data[data.startIndex...cut])
        self[keyPath: keyPath] = Array(data[data.index(after: cut)...])
        return lines
    }

    // MARK: - Sealing at end-of-stream

    /// The lines still owed to the log when `finish()` seals the buffer: each
    /// stream's trailing partial line (if the buffer wasn't binary or
    /// truncated), or the truncation-marker/binary-placeholder line otherwise.
    /// Both arrays are typically single lines — `ShellRunner` appends them via
    /// `ShellState.appendLines` exactly like any other incremental flush.
    struct FinalLines: Sendable, Equatable {
        /// Stdout line(s) owed at end-of-stream.
        var stdout: [String] = []
        /// Stderr line(s) owed at end-of-stream.
        var stderr: [String] = []
    }

    /// Seal the buffer at end-of-stream. No further `append`/
    /// `extractCompleted*Lines` calls are expected afterward.
    ///
    /// - If binary content was detected, both streams' resident bytes are
    ///   discarded and a single `[Binary content: {n} bytes]` line is
    ///   returned, sized by the cumulative `storedByteCount` — not either
    ///   stream's own (now mostly-drained) resident byte count, which by this
    ///   point reflects only whatever hasn't yet been incrementally flushed.
    /// - Otherwise, each stream's still-buffered trailing partial line (text
    ///   with no closing `\n`) is flushed. If output was truncated, the
    ///   truncation-marker line (`Self.truncationMarker`) is appended after
    ///   whichever stream has a trailing line, preferring stdout, or into
    ///   `stdout` if neither stream has one.
    mutating func finish() -> FinalLines {
        if binaryDetected {
            stdoutData = []
            stderrData = []
            return FinalLines(stdout: [Self.binaryPlaceholder(byteCount: storedByteCount)])
        }

        var result = FinalLines()
        if !stdoutData.isEmpty {
            result.stdout = Self.splitLogLines(stdoutData)
            stdoutData = []
        }
        if !stderrData.isEmpty {
            result.stderr = Self.splitLogLines(stderrData)
            stderrData = []
        }

        if truncated {
            let marker = Self.truncationMarker
            if !result.stdout.isEmpty {
                result.stdout.append(marker)
            } else if !result.stderr.isEmpty {
                result.stderr.append(marker)
            } else {
                result.stdout.append(marker)
            }
        }

        return result
    }

    // MARK: - Helpers

    /// The safe cut point within `data[0..<limit]`: the byte after the last
    /// `\n`, else the last UTF-8 code-point boundary, else `limit`.
    private static func safeTruncationPoint(_ data: [UInt8], upTo limit: Int) -> Int {
        let slice = data[0..<limit]
        if slice.isEmpty { return 0 }
        for index in stride(from: limit - 1, through: 0, by: -1) where data[index] == Self.newlineByte {
            return index + 1
        }
        for index in stride(from: limit - 1, through: 0, by: -1) {
            let byte = data[index]
            if byte & 0x80 == 0 || byte & 0xC0 == 0xC0 {
                return index
            }
        }
        return limit
    }

    /// Whether `data` looks binary: a null byte in its first 8 KiB.
    private static func isBinary(_ data: [UInt8]) -> Bool {
        guard !data.isEmpty else { return false }
        let sampleCount = min(data.count, binaryDetectionSampleBytes)
        for index in 0..<sampleCount where data[index] == 0 {
            return true
        }
        return false
    }

    /// Format stored bytes: the binary placeholder (sized by the cumulative
    /// `storedByteCount`, not this stream's own resident `data.count` — see
    /// `binaryPlaceholder(byteCount:)`) if binary, otherwise a lossy-UTF-8
    /// decode of the raw bytes.
    private static func format(_ data: [UInt8], binaryDetected: Bool, storedByteCount: Int) -> String {
        if binaryDetected || isBinary(data) {
            return binaryPlaceholder(byteCount: storedByteCount)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Split a stored stream into log lines the same way `ShellState` scans the
    /// log back, adding this buffer's binary-detection wrapper: a binary stream
    /// collapses to its single placeholder line, while text delegates to the
    /// shared `splitLogLines`.
    private func logLines(from data: [UInt8]) -> [String] {
        // An empty stream contributes no log lines — even when the *other*
        // stream flipped the shared binary flag, there is nothing here to stand
        // in for with a placeholder.
        guard !data.isEmpty else { return [] }
        if binaryDetected || Self.isBinary(data) {
            return [Self.format(data, binaryDetected: binaryDetected, storedByteCount: storedByteCount)]
        }
        return Self.splitLogLines(data)
    }

    /// Split raw log bytes into lines the one way the shell log is written and
    /// read back: split on the `\n` **byte** (not a grapheme, so a `\r\n`
    /// cluster still splits), decode each line as lossy UTF-8 so undecodable
    /// output can't abort the scan, and strip a trailing `\r` (CRLF parity with
    /// Rust's `BufRead::lines()`).
    ///
    /// This is the single home for the split-and-decode pipeline shared by
    /// `OutputBuffer.logLines` (via its binary-detection wrapper) and
    /// `ShellState.readLogLines` (via its file-reading wrapper); both delegate
    /// here so a change to CRLF handling, encoding, or splitting is made once.
    /// Generic over any `UInt8` collection so callers pass `[UInt8]` or `Data`
    /// without a full-buffer copy.
    static func splitLogLines<Bytes: Collection>(_ data: Bytes) -> [String]
    where Bytes.Element == UInt8 {
        data
            .split(separator: Self.newlineByte, omittingEmptySubsequences: true)
            .map { lineBytes in
                let line = String(decoding: lineBytes, as: UTF8.self)
                return line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
    }
}
