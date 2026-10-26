import Foundation

/// How a subtitle file was stored on disk, so it can be written back the same way.
/// The exact bytes a document was read from and the text it serialized to at that moment.
/// While the document still serializes to the same text, those bytes are written back, which
/// keeps files with mixed or CR-only line endings identical.
public struct PristineSource: Sendable, Hashable {
    let serialization: String
    let data: Data
}

public struct TextFileTraits: Sendable, Hashable, Codable {
    public enum Encoding: String, Sendable, Codable {
        case utf8, utf16LittleEndian, utf16BigEndian, windows1252
    }

    public var encoding: Encoding
    public var hasBOM: Bool
    /// `"\r\n"` or `"\n"`: the line ending used by the majority of the file.
    public var newline: String
    public var endsWithNewline: Bool
    /// The file was UTF-8 with invalid bytes, replaced by U+FFFD when read.
    public var repairedInvalidBytes = false

    public init(encoding: Encoding = .utf8, hasBOM: Bool = false, newline: String = "\n", endsWithNewline: Bool = true) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.newline = newline
        self.endsWithNewline = endsWithNewline
    }
}

public enum SubtitleDecodingError: Error, LocalizedError, Equatable {
    case undecodable

    public var errorDescription: String? {
        "O arquivo de legenda não está em UTF-8, UTF-16 nem Windows-1252 e não pôde ser lido."
    }
}

enum TextDecoder {
    /// Decodes subtitle bytes. UTF-8 (with or without BOM) and UTF-16 with BOM are exact;
    /// anything else falls back to Windows-1252, the usual encoding of old SSA/SRT files.
    static func decode(_ data: Data) throws -> (String, TextFileTraits) {
        var traits = TextFileTraits()
        let bytes = [UInt8](data.prefix(3))
        let text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            traits.hasBOM = true
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            traits.hasBOM = true
            traits.encoding = .utf16LittleEndian
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            traits.hasBOM = true
            traits.encoding = .utf16BigEndian
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if looksLikeDamagedUTF8(data) {
            // Mostly valid UTF-8 with a few broken bytes: reading it as Windows-1252 would turn
            // every accent into mojibake ("Olá" → "OlÃ¡"). Keep UTF-8 and mark the bad bytes.
            traits.repairedInvalidBytes = true
            text = String(decoding: data, as: UTF8.self)
        } else {
            traits.encoding = .windows1252
            text = String(data: data, encoding: .windowsCP1252)
        }
        guard let decoded = text else { throw SubtitleDecodingError.undecodable }
        let crlf = decoded.components(separatedBy: "\r\n").count - 1
        let lf = decoded.reduce(0) { $1 == "\n" || $1 == "\r\n" ? $0 + 1 : $0 }
        traits.newline = crlf * 2 >= lf && crlf > 0 ? "\r\n" : "\n"
        // Compare scalars: as Characters, a CRLF ending is "\r\n", which `hasSuffix("\n")` rejects.
        traits.endsWithNewline = decoded.unicodeScalars.last.map { $0 == "\n" || $0 == "\r" } ?? false
        return (decoded, traits)
    }

    /// Counts well-formed multi-byte UTF-8 sequences against stray high bytes.
    static func looksLikeDamagedUTF8(_ data: Data) -> Bool {
        var valid = 0, invalid = 0
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            let length = byte < 0x80 ? 1 : byte >> 5 == 0b110 ? 2 : byte >> 4 == 0b1110 ? 3 : byte >> 3 == 0b11110 ? 4 : 0
            if length == 1 { i += 1; continue }
            if length == 0 || i + length > data.endIndex || !data[(i + 1)..<(i + length)].allSatisfy({ $0 >> 6 == 0b10 }) {
                invalid += 1
                i += 1
                continue
            }
            valid += 1
            i += length
        }
        return valid > 0 && valid >= invalid * 4
    }

    /// Splits on `\r\n`, `\n` or lone `\r`, without the terminators. A trailing terminator
    /// does not produce an extra empty line (that is recorded in `TextFileTraits`).
    static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        // Swift treats "\r\n" as a single Character, which keeps CRLF files intact here.
        for character in text {
            if character == "\n" || character == "\r\n" || character == "\r" {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func encode(_ text: String, traits: TextFileTraits) -> Data {
        var data = Data()
        switch traits.encoding {
        case .utf8, .windows1252:
            // Windows-1252 input is written back as UTF-8: every subtitle renderer the app
            // targets reads UTF-8, and re-encoding to 1252 could lose translated characters.
            if traits.hasBOM || traits.encoding == .windows1252 { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(Data(text.utf8))
        case .utf16LittleEndian:
            data.append(contentsOf: [0xFF, 0xFE])
            data.append(text.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BigEndian:
            data.append(contentsOf: [0xFE, 0xFF])
            data.append(text.data(using: .utf16BigEndian) ?? Data())
        }
        return data
    }
}

extension String {
    /// Replaces every line terminator (LF, CR, CRLF, U+0085, U+2028, U+2029, VT, FF) with
    /// `replacement`, so edited text can never split a line of the subtitle file.
    func replacingLineTerminators(with replacement: String) -> String {
        var output = ""
        output.reserveCapacity(utf8.count)
        for character in self {
            if character.isNewline { output += replacement } else { output.append(character) }
        }
        return output
    }
}
