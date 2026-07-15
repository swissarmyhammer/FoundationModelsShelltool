// `OutputBuffer` — captures a command's stdout and stderr under a shared byte
// cap, truncating at line boundaries and detecting binary content.
//
// A direct behavioral port of the Rust `OutputBuffer`
// (`swissarmyhammer-tools` `mcp/tools/shell/infrastructure.rs`):
//
//   - One `maxSize` cap shared across stdout + stderr (`currentSize` is the sum
//     of both stored buffers). Bytes past the cap are dropped, but every byte is
//     counted in `totalBytesProcessed`.
//   - Truncation prefers a line boundary: the last `\n` in the fitting prefix,
//     else a UTF-8 code-point boundary, so a stored buffer is never cut through
//     a multi-byte scalar.
//   - Binary detection: a null byte within the first 8 KiB of any appended chunk
//     flags the whole capture binary; a binary stream renders as
//     `[Binary content: {n} bytes]` instead of its raw bytes.
//   - No ANSI stripping — output is stored raw (parity).
//
// `ShellRunner` feeds this buffer the raw stdout/stderr chunks and then hands
// its `stdoutLines` / `stderrLines` to `ShellState.appendLines`. Lines are
// derived exactly the way `ShellState` scans the log back (`\n` split, trailing
// `\r` dropped) so what is stored round-trips identically.

import Foundation

/// A size-capped capture buffer for one command's stdout and stderr.
struct OutputBuffer {
    /// The `\n`-prefixed marker appended when output was truncated.
    static let truncationMarker = "\n[Output truncated - exceeded size limit]"
    /// Bytes of an appended chunk scanned for a null byte during binary sniffing.
    static let binaryDetectionSampleBytes = 8 * 1024

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
    var stdout: String { Self.format(stdoutData, binaryDetected: binaryDetected) }

    /// The formatted stderr: the binary placeholder if binary, else lossy UTF-8.
    var stderr: String { Self.format(stderrData, binaryDetected: binaryDetected) }

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

        let available = max(0, maxSize - currentSize)
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
        return actual
    }

    // MARK: - Truncation marker

    /// Append the truncation marker if output was truncated and the marker fits
    /// within the cap, making room by trimming stored bytes to a line boundary.
    mutating func addTruncationMarker() {
        guard truncated else { return }

        let marker = Array(Self.truncationMarker.utf8)
        var available = max(0, maxSize - currentSize)
        if available < marker.count {
            makeRoom(for: marker.count - available)
        }
        available = max(0, maxSize - currentSize)
        guard available >= marker.count else { return }

        if !stdoutData.isEmpty {
            stdoutData.append(contentsOf: marker)
        } else if !stderrData.isEmpty {
            stderrData.append(contentsOf: marker)
        } else {
            stdoutData.append(contentsOf: marker)
        }
    }

    private mutating func makeRoom(for neededSpace: Int) {
        if !stdoutData.isEmpty {
            stdoutData.removeLast(min(neededSpace, stdoutData.count))
            Self.trimToLineBoundary(&stdoutData)
        } else if !stderrData.isEmpty {
            stderrData.removeLast(min(neededSpace, stderrData.count))
            Self.trimToLineBoundary(&stderrData)
        }
    }

    // MARK: - Helpers

    /// The safe cut point within `data[0..<limit]`: the byte after the last
    /// `\n`, else the last UTF-8 code-point boundary, else `limit`.
    private static func safeTruncationPoint(_ data: [UInt8], upTo limit: Int) -> Int {
        let slice = data[0..<limit]
        if slice.isEmpty { return 0 }
        for index in stride(from: limit - 1, through: 0, by: -1) where data[index] == UInt8(ascii: "\n") {
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

    private static func trimToLineBoundary(_ buffer: inout [UInt8]) {
        while let last = buffer.last, last != UInt8(ascii: "\n") {
            buffer.removeLast()
        }
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

    /// Format stored bytes: the binary placeholder (with the stored byte count)
    /// if binary, otherwise a lossy-UTF-8 decode of the raw bytes.
    private static func format(_ data: [UInt8], binaryDetected: Bool) -> String {
        if binaryDetected || isBinary(data) {
            return "[Binary content: \(data.count) bytes]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Split a stored stream into log lines the same way `ShellState` scans the
    /// log back: split on the `\n` **byte** (not a grapheme, so a `\r\n` cluster
    /// still splits), decode each line as lossy UTF-8, and strip a trailing `\r`
    /// (CRLF parity with Rust's `BufRead::lines()`). A binary stream collapses to
    /// its single placeholder line.
    private func logLines(from data: [UInt8]) -> [String] {
        // An empty stream contributes no log lines — even when the *other*
        // stream flipped the shared binary flag, there is nothing here to stand
        // in for with a placeholder.
        guard !data.isEmpty else { return [] }
        if binaryDetected || Self.isBinary(data) {
            return [Self.format(data, binaryDetected: binaryDetected)]
        }
        return data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { lineBytes in
                let line = String(decoding: lineBytes, as: UTF8.self)
                return line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
    }
}
