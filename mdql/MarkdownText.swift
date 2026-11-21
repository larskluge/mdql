import Foundation

/// How mdql read a Markdown file's bytes as text. Crosses the XPC boundary
/// with the text the service read.
@objc enum MarkdownEncoding: Int {
    case utf8
    case utf16
    case windowsLatin1
    case isoLatin1

    /// Its name as the reader knows it.
    var name: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .windowsLatin1: return "Windows Latin-1"
        case .isoLatin1: return "ISO Latin-1"
        }
    }
}

/// Why something the reader asked for did not happen, in plain words for a
/// notice: "file not found", not an error dump.
struct PlainError: Error, Equatable {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    static let fileNotFound = PlainError("file not found")
    static let helperDidntAnswer = PlainError("mdql's helper didn't answer")

    /// `error`, which reading or writing a file threw, in plain words.
    init(describing error: Error) {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                self = .fileNotFound
                return
            case NSFileReadNoPermissionError:
                self.init(errno: EACCES, reading: true)
                return
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                self.init(errno: EACCES, reading: false)
                return
            default:
                break
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            self.init(errno: Int32(underlying.code), reading: true)
        } else if error.domain == NSPOSIXErrorDomain {
            self.init(errno: Int32(error.code), reading: true)
        } else {
            self.init(error.localizedDescription)
        }
    }

    /// `code`, an `errno` from reading or writing a file, in plain words.
    init(errno code: Int32, reading: Bool) {
        switch code {
        case ENOENT, ENOTDIR:
            self = .fileNotFound
        case EACCES, EPERM, EROFS:
            self.init(reading ? "no permission to read it" : "the file is read-only")
        default:
            self.init(String(cString: strerror(code)).lowercased())
        }
    }
}

/// A Markdown file's text, decoded the one way every reader in mdql decodes
/// it: the Quick Look preview, the viewer, and the XPC service on the
/// preview's behalf. A file that is not UTF-8 is shown anyway, as the
/// encoding it most likely is.
struct MarkdownText {
    let string: String
    let encoding: MarkdownEncoding

    init(string: String, encoding: MarkdownEncoding) {
        self.string = string
        self.encoding = encoding
    }

    /// A UTF-16 or UTF-8 byte-order mark decides; else UTF-8 if the bytes are
    /// valid UTF-8, else Windows Latin-1, else ISO Latin-1, which decodes any
    /// bytes at all. Decoding drops a byte-order mark, as `CheckboxToggle`
    /// expects.
    init(data: Data) {
        let bytes = data.prefix(3)
        if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]),
           let string = String(data: data, encoding: .utf16) {
            self.init(string: string, encoding: .utf16)
        } else if let string = String(data: data, encoding: .utf8) {
            self.init(string: string, encoding: .utf8)
        } else if let string = String(data: data, encoding: .windowsCP1252) {
            self.init(string: string, encoding: .windowsLatin1)
        } else {
            // Each byte is the code point of the same number.
            self.init(string: String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) })), encoding: .isoLatin1)
        }
    }

    /// Reads and decodes the file at `url`, throwing the read error itself.
    init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url))
    }

    /// The file at `url`, or why it could not be read, in plain words.
    static func read(_ url: URL) -> Result<MarkdownText, PlainError> {
        Result { try MarkdownText(contentsOf: url) }.mapError(PlainError.init(describing:))
    }
}
