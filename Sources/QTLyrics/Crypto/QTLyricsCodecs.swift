import Foundation

public enum QTLyricsCodecError: Error, Sendable, Equatable {
    case badHeader
    case badHex
    case notText
    case inflateFailed
}

/// Kugou KRC: `"krc1"` + zlib stream XOR-ed with a 16-byte key.
public enum QTKRCCodec {
    static let magic: [UInt8] = Array("krc1".utf8)
    static let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]

    public static func decrypt(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        guard bytes.count > 4, Array(bytes[0..<4]) == magic else { throw QTLyricsCodecError.badHeader }
        var body = [UInt8](bytes[4...])
        for i in body.indices { body[i] ^= key[i & 15] }
        guard let inflated = try? QTZlib.inflate(Data(body)) else { throw QTLyricsCodecError.inflateFailed }
        guard let text = String(data: inflated, encoding: .utf8) else { throw QTLyricsCodecError.notText }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Base64 `content` field of Kugou's download response.
    public static func decrypt(base64 content: String) throws -> String {
        guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { throw QTLyricsCodecError.badHeader }
        return try decrypt(data)
    }

    /// Inverse of `decrypt` (tests and fixtures).
    public static func encrypt(_ text: String) -> Data {
        var body = [UInt8](QTZlib.deflate(Data(text.utf8)))
        for i in body.indices { body[i] ^= key[i & 15] }
        return Data(magic + body)
    }
}

/// QQ Music QRC: hex string → QQ's triple-DES variant → zlib.
public enum QTQRCCodec {
    public static func decrypt(hex: String) throws -> String {
        guard let bytes = Self.bytes(fromHex: hex), !bytes.isEmpty, bytes.count % 8 == 0 else { throw QTLyricsCodecError.badHex }
        let plain = QTQQMusicDES.process(bytes, mode: .decrypt)
        guard let inflated = try? QTZlib.inflate(Data(plain)) else { throw QTLyricsCodecError.inflateFailed }
        guard let text = String(data: inflated, encoding: .utf8) else { throw QTLyricsCodecError.notText }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Inverse of `decrypt` (tests and fixtures). Zero-pads the zlib stream to the 8-byte block size.
    public static func encrypt(_ text: String) -> String {
        var z = [UInt8](QTZlib.deflate(Data(text.utf8)))
        while z.count % 8 != 0 { z.append(0) }
        return QTQQMusicDES.process(z, mode: .encrypt).map { String(format: "%02X", $0) }.joined()
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 65...70: v = c - 55
            case 97...102: v = c - 87
            case 32, 10, 13: continue
            default: return nil
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        return high == nil ? out : nil
    }
}
