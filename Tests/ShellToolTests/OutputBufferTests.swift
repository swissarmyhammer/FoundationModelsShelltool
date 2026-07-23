import Foundation
import Testing

@testable import ShellTool

/// Unit tests for `OutputBuffer` — the byte-accumulating capture buffer with a
/// shared size cap, line-boundary truncation, and binary-content detection.
/// A direct behavioral port of the Rust `OutputBuffer` (shell/infrastructure.rs).
@Suite struct OutputBufferTests {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - Basic capture

    @Test func underLimitOutputIsCapturedVerbatim() {
        var buffer = OutputBuffer(maxSize: 1000)
        let written = buffer.appendStdout(bytes("hello world\n"))
        #expect(written == 12)
        #expect(buffer.currentSize == 12)
        #expect(!buffer.truncated)
        #expect(!buffer.binaryDetected)
        #expect(buffer.stdout == "hello world\n")
        #expect(buffer.stdoutLines == ["hello world"])
    }

    @Test func totalBytesProcessedCountsEverythingIncludingDropped() {
        var buffer = OutputBuffer(maxSize: 10)
        _ = buffer.appendStdout(bytes("0123456789ABCDEF"))  // 16 bytes, cap 10
        #expect(buffer.totalBytesProcessed == 16)
        #expect(buffer.currentSize <= 10)
        #expect(buffer.truncated)
    }

    // MARK: - Combined cap across stdout + stderr

    @Test func sizeCapIsSharedAcrossStdoutAndStderr() {
        var buffer = OutputBuffer(maxSize: 20)
        _ = buffer.appendStdout(bytes("aaaaaaaaaa\n"))  // 11 bytes
        let written = buffer.appendStderr(bytes("bbbbbbbbbbbbbbbbbbbb\n"))  // 21 bytes
        #expect(written <= 9)  // only 20 - 11 = 9 left
        #expect(buffer.currentSize <= 20)
        #expect(buffer.truncated)
    }

    // MARK: - Line-boundary truncation

    @Test func exactlyAtCapIsNotTruncated() {
        var buffer = OutputBuffer(maxSize: 12)
        let written = buffer.appendStdout(bytes("line1\nline2\n"))  // exactly 12
        #expect(written == 12)
        #expect(!buffer.truncated)
        #expect(buffer.isAtLimit)
        #expect(buffer.stdoutLines == ["line1", "line2"])
    }

    @Test func justOverCapTruncatesAtLineBoundary() {
        var buffer = OutputBuffer(maxSize: 12)
        // 18 bytes; only 12 fit, and the safe cut is the newline after "line2".
        _ = buffer.appendStdout(bytes("line1\nline2\nline3\n"))
        #expect(buffer.truncated)
        #expect(buffer.currentSize <= 12)
        // Truncation lands on a line boundary: no partial "line3".
        #expect(buffer.stdoutLines == ["line1", "line2"])
    }

    // MARK: - Binary detection

    @Test func nullByteMarksContentBinaryAndReplacesOutput() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout([0x00, 0x01, 0x02, 0xFF] + bytes("abc"))
        #expect(buffer.binaryDetected)
        #expect(buffer.stdout == "[Binary content: 7 bytes]")
        #expect(buffer.stdoutLines == ["[Binary content: 7 bytes]"])
    }

    @Test func liveBinaryPlaceholderMatchesCumulativeStoredByteCountAcrossStreams() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout([0x00] + bytes("abc\n"))  // 5 bytes; null triggers binary
        _ = buffer.appendStderr(bytes("more\n"))  // 5 more bytes, still stored (cumulative)

        // The live `stdout`/`stderr` properties must report the same cumulative
        // byte count as `finish()` does for the same event — not each stream's
        // own resident `data.count`.
        #expect(buffer.stdout == "[Binary content: 10 bytes]")
        #expect(buffer.stderr == "[Binary content: 10 bytes]")

        let final = buffer.finish()
        #expect(final.stdout == ["[Binary content: 10 bytes]"])
    }

    @Test func plainTextIsNotFlaggedBinary() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("normal\ttext with tabs\r\nand crlf\n"))
        #expect(!buffer.binaryDetected)
    }

    @Test func nullByteWithinFirst8KiBIsFlaggedBinary() {
        var buffer = OutputBuffer(maxSize: 20 * 1024)
        // A null exactly at the last scanned byte (index sampleBytes - 1) is seen.
        var data = [UInt8](repeating: UInt8(ascii: "a"), count: OutputBuffer.binaryDetectionSampleBytes)
        data[OutputBuffer.binaryDetectionSampleBytes - 1] = 0
        _ = buffer.appendStdout(data)
        #expect(buffer.binaryDetected)
    }

    @Test func nullBytePastFirst8KiBIsNotFlaggedBinary() {
        var buffer = OutputBuffer(maxSize: 20 * 1024)
        // A null just past the 8 KiB sample window is not scanned, so not flagged.
        var data = [UInt8](repeating: UInt8(ascii: "a"), count: OutputBuffer.binaryDetectionSampleBytes + 1)
        data[OutputBuffer.binaryDetectionSampleBytes] = 0
        _ = buffer.appendStdout(data)
        #expect(!buffer.binaryDetected)
    }

    // MARK: - Line derivation parity with ShellState's log scan

    @Test func stdoutLinesStripTrailingCarriageReturn() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("carriage\r\nplain\n"))
        #expect(buffer.stdoutLines == ["carriage", "plain"])
    }

    // MARK: - Incremental completed-line extraction

    @Test func extractCompletedStdoutLinesHoldsBackThePartialLineUntilItCompletes() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("first\nsecond-par"))
        #expect(buffer.extractCompletedStdoutLines() == ["first"])
        // The trailing partial line has no `\n` yet — nothing new to extract.
        #expect(buffer.extractCompletedStdoutLines() == [])

        _ = buffer.appendStdout(bytes("tial\nthird\n"))
        #expect(buffer.extractCompletedStdoutLines() == ["second-partial", "third"])
    }

    @Test func extractCompletedStderrLinesIsIndependentOfStdout() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("out-only\n"))
        _ = buffer.appendStderr(bytes("err-only\n"))
        #expect(buffer.extractCompletedStderrLines() == ["err-only"])
        #expect(buffer.extractCompletedStdoutLines() == ["out-only"])
    }

    @Test func extractCompletedStdoutLinesReturnsEmptyWhenNoNewlineHasArrivedYet() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("no newline at all"))
        #expect(buffer.extractCompletedStdoutLines() == [])
    }

    // MARK: - Cumulative stored-bytes cap (distinct from totalBytesProcessed)

    @Test func storedByteCountIsCumulativeAndSurvivesExtraction() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("abc\n"))  // 4 bytes
        _ = buffer.extractCompletedStdoutLines()
        // Extraction drains the resident buffer back toward empty…
        #expect(buffer.currentSize == 0)
        // …but the cumulative counter still remembers those 4 bytes were stored.
        #expect(buffer.storedByteCount == 4)
    }

    @Test func cumulativeCapStaysEnforcedAcrossIncrementalFlushes() {
        // Cap of 10 bytes. Flushing the first chunk out via extraction drains
        // `currentSize` back toward 0 — but the cap must still be tracked
        // cumulatively, so a chatty command can't reopen room under the cap by
        // having its lines flushed out from under it.
        var buffer = OutputBuffer(maxSize: 10)
        _ = buffer.appendStdout(bytes("aaaaa\n"))  // 6 bytes
        _ = buffer.extractCompletedStdoutLines()
        #expect(buffer.currentSize == 0)

        let written = buffer.appendStdout(bytes("bbbbbbbbbb\n"))  // 11 bytes; only 4 should fit
        #expect(written <= 4)
        #expect(buffer.truncated)
    }

    // MARK: - Binary detection suppresses further incremental extraction

    @Test func binaryDetectionStopsFurtherIncrementalExtractionOnBothStreams() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout([0x00] + bytes("bin\n"))
        #expect(buffer.binaryDetected)
        #expect(buffer.extractCompletedStdoutLines() == [])

        _ = buffer.appendStderr(bytes("more\n"))
        #expect(buffer.extractCompletedStderrLines() == [])
    }

    // MARK: - finish(): trailing partial line + truncation marker as its own line

    @Test func finishFlushesTheTrailingPartialLineWithNoClosingNewline() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout(bytes("complete\nno-newline-yet"))
        #expect(buffer.extractCompletedStdoutLines() == ["complete"])

        let final = buffer.finish()
        #expect(final.stdout == ["no-newline-yet"])
        #expect(final.stderr == [])
    }

    @Test func finishAppendsTheTruncationMarkerAsItsOwnLine() {
        var buffer = OutputBuffer(maxSize: 12)
        _ = buffer.appendStdout(bytes("line1\nline2\nline3\n"))  // exceeds the cap
        _ = buffer.extractCompletedStdoutLines()
        #expect(buffer.truncated)

        let final = buffer.finish()
        #expect(final.stdout.last == "[Output truncated - exceeded size limit]")
    }

    @Test func finishEmitsOneBinaryPlaceholderLineUsingTheCumulativeStoredByteCount() {
        var buffer = OutputBuffer(maxSize: 1000)
        _ = buffer.appendStdout([0x00] + bytes("abc\n"))  // 5 bytes; null triggers binary
        _ = buffer.appendStderr(bytes("more\n"))  // 5 more bytes, still stored (cumulative)

        let final = buffer.finish()
        #expect(final.stdout == ["[Binary content: 10 bytes]"])
        #expect(final.stderr == [])
    }
}
