import Foundation
import zlib

/// The platform gzip codec is bounded before allocating output. Concatenated
/// members, trailing data and a claimed size that does not match are refused.
enum CloudSecretsCompression {
    static func encode(_ bytes: Data, codec: CloudContentCodec) throws -> Data {
        guard bytes.count <= CloudWire.maximumPlainChunkBytes else { throw CloudFailure.invalidRequest }
        if codec == .identity { return bytes }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                           ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CloudFailure.unavailable }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(bytes.count))))
        let capacity = output.count
        let result = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(bytes.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.avail_in == 0 else { throw CloudFailure.invalidRequest }
        output.count = Int(stream.total_out)
        return output
    }
    static func decode(_ bytes: Data, codec: CloudContentCodec, expected: Int64) throws -> Data {
        guard (0...Int64(CloudWire.maximumPlainChunkBytes)).contains(expected) else { throw CloudFailure.invalidRequest }
        if codec == .identity {
            guard bytes.count == expected else { throw CloudFailure.checksumMismatch }
            return bytes
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CloudFailure.unavailable }
        defer { inflateEnd(&stream) }
        let capacity = Int(expected) + 1
        var output = Data(count: capacity)
        let result = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(bytes.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.avail_in == 0, stream.total_out == expected else { throw CloudFailure.checksumMismatch }
        output.count = Int(expected)
        return output
    }
}
