import Foundation

/// Shared wire framing for OpenAI-compatible streaming providers.
///
/// Keep provider-specific product behavior (billing, account updates,
/// diagnostics) outside this type. This layer only turns bytes/lines into
/// provider event payloads and applies explicitly enabled compatibility
/// tolerances for OpenAI-compatible APIs.
struct OpenAICompatibleStreamFramer {
    struct Options: Sendable, Equatable {
        var allowsRawJSONBodyFallback: Bool = false
        var repairsSplitDataJSON: Bool = false

        static let strict = Options()
        static let routerCompatible = Options(
            allowsRawJSONBodyFallback: true,
            repairsSplitDataJSON: true
        )
    }

    /// Byte-level SSE line tokenizer. Splits a stream of bytes into logical SSE
    /// lines, treating LF, CR, and CRLF as line terminators. It intentionally
    /// does not split on Unicode separators such as U+2028, which can appear
    /// inside JSON string values.
    struct SSELineParser {
        private var lineBuffer = Data()
        private var carriageReturnLast = false
        private var completedLines: [Data] = []
        private var nextOutputIndex = 0

        /// Bulk newline scan: finds terminators with `memchr` and copies whole
        /// line spans at once instead of appending byte-by-byte (the previous
        /// per-byte loop dominated the SSE hot path on large deltas).
        /// Semantics are identical: LF, CR, and CRLF all terminate a line, a
        /// CRLF split across chunk boundaries yields one line, and a blank
        /// line is emitted as an empty `Data` (SSE event boundary).
        mutating func append(_ data: Data) {
            guard !data.isEmpty else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let rawBase = raw.baseAddress else { return }
                let base = rawBase.assumingMemoryBound(to: UInt8.self)
                let count = raw.count
                var offset = 0
                if carriageReturnLast {
                    carriageReturnLast = false
                    if base[0] == 0x0A { offset = 1 }
                }
                while offset < count {
                    let remaining = count - offset
                    let lfOffset = memchr(base + offset, 0x0A, remaining)
                        .map { UnsafeRawPointer($0) - rawBase }
                    let crOffset = memchr(base + offset, 0x0D, remaining)
                        .map { UnsafeRawPointer($0) - rawBase }

                    let terminatorOffset: Int
                    let terminatorIsCR: Bool
                    switch (lfOffset, crOffset) {
                    case (nil, nil):
                        // No terminator in the rest of the chunk — stash the
                        // partial line and wait for more bytes.
                        lineBuffer.append(base + offset, count: remaining)
                        return
                    case (let lf?, nil):
                        terminatorOffset = lf
                        terminatorIsCR = false
                    case (nil, let cr?):
                        terminatorOffset = cr
                        terminatorIsCR = true
                    case (let lf?, let cr?):
                        terminatorIsCR = cr < lf
                        terminatorOffset = min(lf, cr)
                    }

                    let lineLength = terminatorOffset - offset
                    if lineBuffer.isEmpty {
                        completedLines.append(Data(bytes: base + offset, count: lineLength))
                    } else {
                        lineBuffer.append(base + offset, count: lineLength)
                        completedLines.append(lineBuffer)
                        lineBuffer = Data()
                    }

                    if terminatorIsCR {
                        if terminatorOffset + 1 < count {
                            // Swallow an immediately-following LF (CRLF).
                            offset =
                                base[terminatorOffset + 1] == 0x0A
                                ? terminatorOffset + 2 : terminatorOffset + 1
                        } else {
                            // CR is the chunk's last byte: remember it so an
                            // LF at the head of the next chunk is swallowed.
                            carriageReturnLast = true
                            offset = count
                        }
                    } else {
                        offset = terminatorOffset + 1
                    }
                }
            }
        }

        mutating func nextLine() -> Data? {
            guard nextOutputIndex < completedLines.count else {
                if nextOutputIndex > 0 {
                    completedLines.removeFirst(nextOutputIndex)
                    nextOutputIndex = 0
                }
                return nil
            }
            let line = completedLines[nextOutputIndex]
            nextOutputIndex += 1
            return line
        }

        mutating func flushPending() {
            if !lineBuffer.isEmpty {
                completedLines.append(lineBuffer)
                lineBuffer = Data()
            }
            carriageReturnLast = false
        }
    }

    @inline(__always)
    static func processLine(_ line: Data, into eventData: inout String) {
        processLine(line, options: .strict, into: &eventData)
    }

    @inline(__always)
    static func processLine(_ line: Data, options: Options, into eventData: inout String) {
        guard !line.isEmpty else { return }

        if options.allowsRawJSONBodyFallback,
            shouldAppendRawJSONContinuation(line, currentEventData: eventData)
        {
            eventData += "\n" + String(decoding: line, as: UTF8.self)
            return
        }

        if options.allowsRawJSONBodyFallback,
            shouldTreatLineAsRawJSON(line, currentEventData: eventData)
        {
            eventData = String(decoding: line, as: UTF8.self)
            return
        }

        processSSEFieldLine(line, into: &eventData)
    }

    static func repairedSplitDataJSONPayload(_ jsonData: Data, options: Options) -> Data? {
        guard options.repairsSplitDataJSON,
            let payload = String(data: jsonData, encoding: .utf8),
            payload.contains("\n")
        else { return nil }

        // Some OpenAI-compatible proxies incorrectly split one JSON SSE payload
        // across multiple data: lines. The spec joins those with LF, which is
        // correct for compliant streams but makes illegal literal newlines
        // inside JSON strings for the broken stream. Retry with only framing
        // CR/LF removed after strict JSON decode has failed.
        let normalized =
            payload
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard normalized != payload else { return nil }
        return normalized.data(using: .utf8)
    }

    @inline(__always)
    private static func processSSEFieldLine(_ line: Data, into eventData: inout String) {
        let lineStr = String(decoding: line, as: UTF8.self)
        if lineStr.first == ":" { return }

        let field: Substring
        var value: Substring
        if let colonIdx = lineStr.firstIndex(of: ":") {
            field = lineStr[..<colonIdx]
            value = lineStr[lineStr.index(after: colonIdx)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(lineStr)
            value = Substring("")
        }

        guard field == "data" else { return }
        if eventData.isEmpty {
            eventData = String(value)
        } else {
            eventData += "\n" + value
        }
    }

    @inline(__always)
    private static func shouldAppendRawJSONContinuation(
        _ line: Data,
        currentEventData: String
    ) -> Bool {
        guard let firstEventByte = currentEventData.utf8.first(where: { !isASCIIWhitespace($0) }),
            firstEventByte == UInt8(ascii: "{") || firstEventByte == UInt8(ascii: "[")
        else { return false }
        return !looksLikeSSEFieldLine(line)
    }

    @inline(__always)
    private static func shouldTreatLineAsRawJSON(_ line: Data, currentEventData: String) -> Bool {
        guard currentEventData.isEmpty,
            let first = line.first(where: { !isASCIIWhitespace($0) })
        else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    @inline(__always)
    private static func looksLikeSSEFieldLine(_ line: Data) -> Bool {
        let trimmed = line.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
        if trimmed.first == UInt8(ascii: ":") { return true }
        return trimmed.starts(with: Array("data:".utf8))
            || trimmed.starts(with: Array("event:".utf8))
            || trimmed.starts(with: Array("id:".utf8))
            || trimmed.starts(with: Array("retry:".utf8))
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
            return true
        default:
            return false
        }
    }
}
