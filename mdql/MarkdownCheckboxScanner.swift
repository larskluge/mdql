import Foundation

/// Locates GFM task-list checkbox markers in a markdown source string.
///
/// Returns UTF-8 byte offsets of the character between `[` and `]` for each
/// task-list item, in document order. The caller can read or rewrite that
/// single byte to change the checkbox state without touching the rest of the
/// file. Markers inside fenced code blocks are skipped.
enum MarkdownCheckboxScanner {

    static func scan(_ markdown: String) -> [Int] {
        let bytes = Array(markdown.utf8)
        var offsets: [Int] = []
        var fenceChar: UInt8? = nil // 0x60 (`) or 0x7E (~) while inside a fenced block

        var lineStart = 0
        let count = bytes.count
        while lineStart <= count {
            var i = lineStart
            while i < count && bytes[i] != 0x0A { i += 1 }
            let lineEnd = i

            if let openFence = detectFenceOpenOrClose(bytes: bytes, start: lineStart, end: lineEnd) {
                if let active = fenceChar {
                    if openFence == active {
                        fenceChar = nil
                    }
                } else {
                    fenceChar = openFence
                }
            } else if fenceChar == nil,
                      let markerOffset = scanLineForCheckboxMarker(bytes: bytes, start: lineStart, end: lineEnd) {
                offsets.append(markerOffset)
            }

            lineStart = lineEnd + 1
        }
        return offsets
    }

    /// Returns the fence char (0x60 or 0x7E) if this line is a fence delimiter
    /// line, else nil. A fence delimiter is 3+ consecutive ` or ~ at the start
    /// of the line (after optional spaces), optionally followed by an info
    /// string on the same line.
    private static func detectFenceOpenOrClose(bytes: [UInt8], start: Int, end: Int) -> UInt8? {
        var i = start
        while i < end && bytes[i] == 0x20 { i += 1 } // optional leading spaces
        guard i < end else { return nil }
        let ch = bytes[i]
        guard ch == 0x60 || ch == 0x7E else { return nil }
        var run = 0
        while i < end && bytes[i] == ch { i += 1; run += 1 }
        guard run >= 3 else { return nil }
        return ch
    }

    /// Returns byte offset of the char inside `[...]` if this line is a task-list item.
    private static func scanLineForCheckboxMarker(bytes: [UInt8], start: Int, end: Int) -> Int? {
        var i = start

        // Skip leading whitespace.
        while i < end && (bytes[i] == 0x20 || bytes[i] == 0x09) { i += 1 }

        // Expect bullet: `-`, `*`, `+`, or digits followed by `.`.
        guard i < end else { return nil }
        if bytes[i] == 0x2D || bytes[i] == 0x2A || bytes[i] == 0x2B { // - * +
            i += 1
        } else if bytes[i] >= 0x30 && bytes[i] <= 0x39 { // 0-9
            while i < end && bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
            guard i < end && bytes[i] == 0x2E else { return nil } // .
            i += 1
        } else {
            return nil
        }

        // Require at least one space/tab after the bullet.
        guard i < end && (bytes[i] == 0x20 || bytes[i] == 0x09) else { return nil }
        while i < end && (bytes[i] == 0x20 || bytes[i] == 0x09) { i += 1 }

        // Expect `[X]` where X is one of space, x, X.
        guard i + 2 < end else { return nil }
        guard bytes[i] == 0x5B else { return nil } // [
        let markerByte = bytes[i + 1]
        guard markerByte == 0x20 || markerByte == 0x78 || markerByte == 0x58 else { return nil }
        guard bytes[i + 2] == 0x5D else { return nil } // ]

        return i + 1
    }
}
