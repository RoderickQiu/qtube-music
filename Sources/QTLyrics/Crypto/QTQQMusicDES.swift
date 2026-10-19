import Foundation

/// QQ Music's triple-DES variant used for QRC lyrics.
///
/// Structurally it is the classic table-free DES (as in Brad Conte's public-domain crypto-algorithms), with
/// three quirks that make it incompatible with a textbook DES/3DES implementation:
/// 1. bits are addressed inside little-endian 32-bit words (`byte = (bit / 32) * 4 + 3 - (bit % 32) / 8`),
///    both for the data block and for the key;
/// 2. two S-box entries differ from FIPS 46-3 (S2 row 1 col 7 = 15, S4 row 3 col 5 = 10);
/// 3. the 3DES ladder is E(k1) D(k2) E(k3) with the 24-byte key split as k1 = key[0..<8], k2 = key[8..<16],
///    k3 = key[16..<24], and decryption runs the ladder backwards.
/// Implemented independently from the algorithm description; verified against recorded QQ responses.
enum QTQQMusicDES {
    enum Mode { case encrypt, decrypt }

    typealias Schedule = [[UInt8]]   // 16 rounds × 6 bytes

    static let qrcKey: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    // MARK: Triple DES

    static func tripleSchedule(key: [UInt8], mode: Mode) -> [Schedule] {
        let k1 = Array(key[0..<8]), k2 = Array(key[8..<16]), k3 = Array(key[16..<24])
        switch mode {
        case .encrypt: return [schedule(k1, .encrypt), schedule(k2, .decrypt), schedule(k3, .encrypt)]
        case .decrypt: return [schedule(k3, .decrypt), schedule(k2, .encrypt), schedule(k1, .decrypt)]
        }
    }

    /// Processes `data` in 8-byte blocks (ECB). `data.count` must be a multiple of 8.
    static func process(_ data: [UInt8], key: [UInt8] = qrcKey, mode: Mode) -> [UInt8] {
        precondition(data.count % 8 == 0)
        let schedules = tripleSchedule(key: key, mode: mode)
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var block = [UInt8](repeating: 0, count: 8)
        var i = 0
        while i < data.count {
            for j in 0..<8 { block[j] = data[i + j] }
            for s in schedules { block = crypt(block, s) }
            out.append(contentsOf: block)
            i += 8
        }
        return out
    }

    // MARK: Single DES

    private static func bit(_ a: [UInt8], _ b: Int, _ c: Int) -> UInt32 {
        UInt32((a[(b / 32) * 4 + 3 - (b % 32) / 8] >> (7 - UInt8(b % 8))) & 1) << UInt32(c)
    }

    @inline(__always) private static func bitR(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a >> UInt32(31 - b)) & 1) << UInt32(c)
    }

    @inline(__always) private static func bitL(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a << UInt32(b)) & 0x8000_0000) >> UInt32(c)
    }

    @inline(__always) private static func sboxBit(_ a: UInt8) -> Int {
        Int((a & 32) | ((a & 31) >> 1) | ((a & 1) << 4))
    }

    private static let ip0 = [57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
                              61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
    private static let ip1 = [56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2,
                              60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6]
    /// Output byte → base bit of the inverse permutation.
    private static let invBase = [3: 7, 2: 6, 1: 5, 0: 4, 7: 3, 6: 2, 5: 1, 4: 0]
    private static let pbox = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9,
                               1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24]

    private static func crypt(_ input: [UInt8], _ key: Schedule) -> [UInt8] {
        var s0: UInt32 = 0, s1: UInt32 = 0
        for k in 0..<32 {
            s0 |= bit(input, ip0[k], 31 - k)
            s1 |= bit(input, ip1[k], 31 - k)
        }
        for round in 0..<15 {
            let previous = s1
            s1 = f(s1, key[round]) ^ s0
            s0 = previous
        }
        s0 = f(s1, key[15]) ^ s0

        var out = [UInt8](repeating: 0, count: 8)
        for (byte, b) in invBase {
            out[byte] = UInt8(bitR(s1, b, 7) | bitR(s0, b, 6) | bitR(s1, b + 8, 5) | bitR(s0, b + 8, 4)
                | bitR(s1, b + 16, 3) | bitR(s0, b + 16, 2) | bitR(s1, b + 24, 1) | bitR(s0, b + 24, 0))
        }
        return out
    }

    private static func f(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        let t1 = bitL(state, 31, 0) | ((state & 0xF000_0000) >> 1) | bitL(state, 4, 5) | bitL(state, 3, 6)
            | ((state & 0x0F00_0000) >> 3) | bitL(state, 8, 11) | bitL(state, 7, 12)
            | ((state & 0x00F0_0000) >> 5) | bitL(state, 12, 17) | bitL(state, 11, 18)
            | ((state & 0x000F_0000) >> 7) | bitL(state, 16, 23)
        let t2 = bitL(state, 15, 0) | ((state & 0x0000_F000) << 15) | bitL(state, 20, 5) | bitL(state, 19, 6)
            | ((state & 0x0000_0F00) << 13) | bitL(state, 24, 11) | bitL(state, 23, 12)
            | ((state & 0x0000_00F0) << 11) | bitL(state, 28, 17) | bitL(state, 27, 18)
            | ((state & 0x0000_000F) << 9) | bitL(state, 0, 23)
        let l: [UInt8] = [
            UInt8((t1 >> 24) & 0xFF) ^ key[0], UInt8((t1 >> 16) & 0xFF) ^ key[1], UInt8((t1 >> 8) & 0xFF) ^ key[2],
            UInt8((t2 >> 24) & 0xFF) ^ key[3], UInt8((t2 >> 16) & 0xFF) ^ key[4], UInt8((t2 >> 8) & 0xFF) ^ key[5],
        ]
        var s = UInt32(sbox[0][sboxBit(l[0] >> 2)]) << 28
        s |= UInt32(sbox[1][sboxBit(((l[0] & 0x03) << 4) | (l[1] >> 4))]) << 24
        s |= UInt32(sbox[2][sboxBit(((l[1] & 0x0F) << 2) | (l[2] >> 6))]) << 20
        s |= UInt32(sbox[3][sboxBit(l[2] & 0x3F)]) << 16
        s |= UInt32(sbox[4][sboxBit(l[3] >> 2)]) << 12
        s |= UInt32(sbox[5][sboxBit(((l[3] & 0x03) << 4) | (l[4] >> 4))]) << 8
        s |= UInt32(sbox[6][sboxBit(((l[4] & 0x0F) << 2) | (l[5] >> 6))]) << 4
        s |= UInt32(sbox[7][sboxBit(l[5] & 0x3F)])
        var p: UInt32 = 0
        for (c, b) in pbox.enumerated() { p |= bitL(s, b, c) }
        return p
    }

    private static let rotations = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let permC = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
                                58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    private static let permD = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5,
                                60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    private static let compression = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3,
                                      25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39,
                                      50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]

    static func schedule(_ key: [UInt8], _ mode: Mode) -> Schedule {
        var out = Schedule(repeating: [UInt8](repeating: 0, count: 6), count: 16)
        var c: UInt32 = 0, d: UInt32 = 0
        for i in 0..<28 {
            c |= bit(key, permC[i], 31 - i)
            d |= bit(key, permD[i], 31 - i)
        }
        for i in 0..<16 {
            let r = UInt32(rotations[i])
            c = ((c << r) | (c >> (28 - r))) & 0xFFFF_FFF0
            d = ((d << r) | (d >> (28 - r))) & 0xFFFF_FFF0
            let slot = mode == .decrypt ? 15 - i : i
            var sub = [UInt8](repeating: 0, count: 6)
            for j in 0..<24 { sub[j / 8] |= UInt8(bitR(c, compression[j], 7 - j % 8)) }
            for j in 24..<48 { sub[j / 8] |= UInt8(bitR(d, compression[j] - 27, 7 - j % 8)) }
            out[slot] = sub
        }
        return out
    }

    private static let sbox: [[UInt8]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
         0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
         15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
         3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
         13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
         13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
         1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
         13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
         3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
         14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
         11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
         10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
         4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
         13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
         6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
         1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
         2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]
}
