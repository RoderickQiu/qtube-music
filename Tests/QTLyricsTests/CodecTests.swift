import Foundation
import Testing
@testable import QTLyrics

/// The encrypted fixtures were produced from the trimmed plaintext by independent Python implementations
/// (recording-time oracle), so decrypting them checks compatibility with the real services' formats.
@Suite struct CodecTests {
    @Test(arguments: ["perfect", "qingtian", "haphom", "doivoianh", "chungta", "yoruni"])
    func kugouKRCDecryptsRecordedSample(slug: String) throws {
        let download = try #require(QTFixtures.song(slug, "kugou_download.json"))
        let json = try JSONSerialization.jsonObject(with: download) as! [String: Any]
        let content = try #require(json["content"] as? String)
        let expected = try #require(QTFixtures.text("songs/\(slug)/kugou_plain.krc"))
        #expect(try QTKRCCodec.decrypt(base64: content) == expected)
    }

    @Test func krcRoundTrip() throws {
        let text = "[ti:Test]\n[1000,500]<0,250,0>Xin <250,250,0>chào\n"
        #expect(try QTKRCCodec.decrypt(QTKRCCodec.encrypt(text)) == text)
        #expect(throws: QTLyricsCodecError.badHeader) { try QTKRCCodec.decrypt(Data("nope".utf8)) }
    }

    @Test(arguments: [("perfect", "lyric"), ("perfect", "trans"), ("qingtian", "lyric"), ("yoruni", "lyric"),
                      ("yoruni", "trans"), ("yoruni", "roma")])
    func qqQRCDecryptsRecordedSample(slug: String, lane: String) throws {
        let response = try #require(QTFixtures.song(slug, "qq_lyric.json"))
        let json = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let data = ((json["req"] as! [String: Any])["data"] as! [String: Any])
        let hex = try #require(data[lane] as? String)
        let expected = try #require(QTFixtures.text("songs/\(slug)/qq_plain_\(lane).txt"))
        #expect(try QTQRCCodec.decrypt(hex: hex) == expected)
    }

    @Test func qrcRoundTrip() throws {
        let text = "<Lyric_1 LyricContent=\"[0,1000]沈(0,500)む(500,500)\"/>"
        let hex = QTQRCCodec.encrypt(text)
        #expect(hex.count % 16 == 0)
        #expect(try QTQRCCodec.decrypt(hex: hex) == text)
        #expect(try QTQRCCodec.decrypt(hex: hex.lowercased()) == text)
        #expect(throws: QTLyricsCodecError.badHex) { try QTQRCCodec.decrypt(hex: "XYZ") }
    }

    @Test func desBlockRoundTripAndAvalanche() {
        let block: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let enc = QTQQMusicDES.process(block, mode: .encrypt)
        #expect(enc != block)
        #expect(QTQQMusicDES.process(enc, mode: .decrypt) == block)
        var flipped = block
        flipped[0] ^= 1
        let enc2 = QTQQMusicDES.process(flipped, mode: .encrypt)
        #expect(zip(enc, enc2).filter { $0 != $1 }.count >= 4)
    }

    @Test func zlibRoundTripIgnoresPadding() throws {
        let original = Data(String(repeating: "lyrics ", count: 200).utf8)
        var compressed = QTZlib.deflate(original)
        compressed.append(contentsOf: [0, 0, 0, 0, 0])
        #expect(try QTZlib.inflate(compressed) == original)
        #expect(throws: (any Error).self) { try QTZlib.inflate(Data([1, 2, 3, 4])) }
    }
}
