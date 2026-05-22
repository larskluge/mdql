import Foundation

/// Flips a single GFM task-list checkbox marker in a file on disk.
///
/// The change is a single-byte write: the character between `[` and `]` is
/// replaced with its opposite (`' '` ⇄ `'x'`). `[X]` is treated as checked
/// and unchecks to `[ ]`. Nothing else in the file is touched — same inode,
/// no full rewrite, no whitespace normalization.
enum CheckboxToggle {

    /// Toggles the `index`-th checkbox in the file. Returns `true` on success.
    /// Returns `false` if the file can't be read, the index is out of range,
    /// or the write fails.
    @discardableResult
    static func toggle(fileAt url: URL, index: Int) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let offsets = MarkdownCheckboxScanner.scan(contents)
        guard index >= 0, index < offsets.count else { return false }
        let byteOffset = offsets[index]

        let bytes = Array(contents.utf8)
        guard byteOffset < bytes.count else { return false }
        let current = bytes[byteOffset]
        let newByte: UInt8
        switch current {
        case 0x20: newByte = 0x78 // space → x
        case 0x78, 0x58: newByte = 0x20 // x|X → space
        default: return false
        }

        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(byteOffset))
            try handle.write(contentsOf: Data([newByte]))
            return true
        } catch {
            return false
        }
    }
}
