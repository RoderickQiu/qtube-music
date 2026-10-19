import Foundation
import zlib

/// zlib (RFC 1950) streams via the system libz. Inflate stops at the end of the stream, so block-cipher
/// padding after it (QRC) is ignored.
enum QTZlib {
    enum Failure: Error { case corrupt(Int32) }

    static func inflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.corrupt(status) }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { throw Failure.corrupt(Z_DATA_ERROR) }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw Failure.corrupt(status) }
                output.append(buffer, count: chunk - Int(stream.avail_out))
                if status == Z_OK, stream.avail_in == 0, stream.avail_out != 0 { throw Failure.corrupt(Z_BUF_ERROR) }
            } while status != Z_STREAM_END
        }
        return output
    }

    static func deflate(_ input: Data) -> Data {
        var length = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let status = input.withUnsafeBytes { raw in
            compress2(&out, &length, raw.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_BEST_COMPRESSION)
        }
        precondition(status == Z_OK, "compress2 failed")
        return Data(out.prefix(Int(length)))
    }
}
