import Foundation

/// What became of a request to set a task-list checkbox, as the XPC service
/// replies it: a failure's reason travels beside it.
@objc enum CheckboxToggleOutcome: Int {
    /// The marker now holds the state asked for.
    case toggled
    /// The file no longer holds the marker the page showed, so nothing was
    /// written: it changed since it was rendered, and must be rendered again.
    case stale
    /// The file could not be opened, read or written.
    case failed
}

/// What became of a request to set a task-list checkbox, and why not when it
/// failed.
enum CheckboxToggleResult: Equatable {
    case toggled
    case stale
    case failed(PlainError)

    /// The result an XPC reply carries: `outcome`, and `reason` when it failed.
    init(outcome: CheckboxToggleOutcome, reason: String?) {
        switch outcome {
        case .toggled: self = .toggled
        case .stale: self = .stale
        case .failed: self = .failed(PlainError(reason ?? "the write failed"))
        }
    }

    /// What an XPC reply carries of it.
    var reply: (outcome: CheckboxToggleOutcome, reason: String?) {
        switch self {
        case .toggled: return (.toggled, nil)
        case .stale: return (.stale, nil)
        case .failed(let error): return (.failed, error.reason)
        }
    }
}

/// Sets a single GFM task-list checkbox marker in a file on disk.
///
/// The change is a single-byte write: the byte between `[` and `]` becomes `x`
/// or a space. Nothing else in the file is touched — same inode, no full
/// rewrite, no whitespace normalization, a byte-order mark kept.
enum CheckboxToggle {

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Sets the marker at `offset` to `checked`. `offset` counts UTF-8 bytes in
    /// the file's text as Foundation decodes it, which is what the renderer's
    /// `data-cb-offset` counts in: a leading byte-order mark, which decoding
    /// drops, is not counted.
    ///
    /// The file is read and written through one descriptor. Nothing is written
    /// unless that byte sits between `[` and `]` and holds the opposite of
    /// `checked`; anything else means the file is not what the page showed.
    static func toggle(fileAt url: URL, offset: Int, checked: Bool) -> CheckboxToggleResult {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return .failed(PlainError(errno: errno, reading: false)) }
        defer { close(fd) }

        let bytes: [UInt8]
        do {
            bytes = Array(try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data())
        } catch {
            return .failed(PlainError(describing: error))
        }
        let position = offset + (bytes.starts(with: byteOrderMark) ? byteOrderMark.count : 0)
        guard offset >= 0, position >= 1, position + 1 < bytes.count,
              bytes[position - 1] == UInt8(ascii: "["), bytes[position + 1] == UInt8(ascii: "]")
        else { return .stale }

        let shown: Bool
        switch bytes[position] {
        case UInt8(ascii: " "): shown = false
        case UInt8(ascii: "x"), UInt8(ascii: "X"): shown = true
        default: return .stale
        }
        guard shown != checked else { return .stale }

        var marker = checked ? UInt8(ascii: "x") : UInt8(ascii: " ")
        switch pwrite(fd, &marker, 1, off_t(position)) {
        case 1: return .toggled
        case -1: return .failed(PlainError(errno: errno, reading: false))
        default: return .failed(PlainError("the write didn't complete"))
        }
    }
}
