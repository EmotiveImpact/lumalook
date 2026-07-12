import Foundation
import Compression

/// Minimal ZIP reader for LUT pack archives (#117). Supports the two
/// storage methods real packs use — stored (0) and deflate (8) — with no
/// third-party dependency. Not a general unzipper: no zip64, no encryption,
/// no spanned archives; unsupported entries are skipped, never fatal.
enum ZipReader {

    struct Entry {
        let fileName: String
        let data: Data
    }

    /// Extracts every readable file entry (directories skipped).
    static func entries(in archiveURL: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: archiveURL), data.count > 22 else { return [] }
        // End-of-central-directory: scan back for PK\x05\x06.
        var eocd = -1
        let floor = max(0, data.count - 66_000)   // EOCD + max comment
        var i = data.count - 22
        while i >= floor {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return [] }
        let entryCount = Int(le16(data, eocd + 10))
        var offset = Int(le32(data, eocd + 16))

        var result: [Entry] = []
        for _ in 0..<entryCount {
            // Central directory header PK\x01\x02.
            guard offset + 46 <= data.count,
                  data[offset] == 0x50, data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x01, data[offset + 3] == 0x02 else { break }
            let method = Int(le16(data, offset + 10))
            let compressedSize = Int(le32(data, offset + 20))
            let uncompressedSize = Int(le32(data, offset + 24))
            let nameLength = Int(le16(data, offset + 28))
            let extraLength = Int(le16(data, offset + 30))
            let commentLength = Int(le16(data, offset + 32))
            let localOffset = Int(le32(data, offset + 42))
            let name = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + nameLength)),
                              encoding: .utf8) ?? ""
            offset += 46 + nameLength + extraLength + commentLength

            guard !name.hasSuffix("/"), uncompressedSize > 0,
                  uncompressedSize < 64_000_000 else { continue }
            // Local header PK\x03\x04 gives the true data start (its own
            // name/extra lengths can differ from the central directory's).
            guard localOffset + 30 <= data.count,
                  data[localOffset] == 0x50, data[localOffset + 1] == 0x4B,
                  data[localOffset + 2] == 0x03, data[localOffset + 3] == 0x04 else { continue }
            let localName = Int(le16(data, localOffset + 26))
            let localExtra = Int(le16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localName + localExtra
            guard dataStart + compressedSize <= data.count else { continue }
            let raw = data.subdata(in: dataStart..<(dataStart + compressedSize))

            switch method {
            case 0:
                result.append(Entry(fileName: name, data: raw))
            case 8:
                if let inflated = inflate(raw, expectedSize: uncompressedSize) {
                    result.append(Entry(fileName: name, data: inflated))
                }
            default:
                continue
            }
        }
        return result
    }

    /// Raw-deflate decode via Compression (ZIP's method 8 is zlib without
    /// the stream header, which is exactly COMPRESSION_ZLIB here).
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        let capacity = max(expectedSize, 64)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity,
                                             base, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
