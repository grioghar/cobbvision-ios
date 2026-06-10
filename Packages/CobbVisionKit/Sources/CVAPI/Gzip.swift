import Foundation
#if canImport(Compression)
import Compression

/// Minimal gzip (RFC 1952) decompressor over Apple's Compression framework.
/// AccessPort datalogs come off the device as `.csv.gz`, and the controlplane's
/// `/api/v1/upload` only accepts plain CSV — so the app inflates locally.
///
/// Apple's `COMPRESSION_ZLIB` is raw DEFLATE, so this parses/strips the gzip
/// header (including optional FEXTRA/FNAME/FCOMMENT/FHCRC fields) and the
/// 8-byte trailer, then streams the DEFLATE payload.
public enum Gzip {
    public enum GzipError: Error, Sendable {
        case notGzip
        case truncated
        case corrupt(String)
    }

    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    public static func decompress(_ data: Data) throws -> Data {
        guard isGzipped(data) else { throw GzipError.notGzip }
        guard data.count > 18 else { throw GzipError.truncated }

        let bytes = [UInt8](data)
        guard bytes[2] == 0x08 else { throw GzipError.corrupt("unsupported compression method \(bytes[2])") }
        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count >= offset + 2 else { throw GzipError.truncated }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { // FNAME — NUL-terminated
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT — NUL-terminated
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset < bytes.count - 8 else { throw GzipError.truncated }

        let deflate = data.subdata(in: data.startIndex.advanced(by: offset)..<data.endIndex.advanced(by: -8))
        let inflated = try inflateRaw(deflate)

        // Trailer: CRC32 + ISIZE (mod 2^32), little-endian.
        let trailer = [UInt8](data.suffix(8))
        let expectedSize = UInt32(trailer[4]) | (UInt32(trailer[5]) << 8)
            | (UInt32(trailer[6]) << 16) | (UInt32(trailer[7]) << 24)
        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize else {
            throw GzipError.corrupt("size mismatch (got \(inflated.count), header says \(expectedSize) mod 2³²)")
        }
        return inflated
    }

    private static func inflateRaw(_ input: Data) throws -> Data {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.corrupt("decoder init failed")
        }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw GzipError.truncated
            }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = input.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(
                    streamPointer,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: bufferSize - streamPointer.pointee.dst_size)
                    if status == COMPRESSION_STATUS_END {
                        return
                    }
                default:
                    throw GzipError.corrupt("deflate stream is invalid")
                }
            }
        }
        return output
    }
}
#endif
