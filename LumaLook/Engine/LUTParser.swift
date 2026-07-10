import Foundation

enum LUTParserError: Error, LocalizedError {
    case missingSize
    case invalidData
    case wrongEntryCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .missingSize: return "Could not find LUT_3D_SIZE in this .cube file."
        case .invalidData: return "The .cube file contains invalid colour data."
        case .wrongEntryCount(let expected, let actual): return "LUT entry count mismatch. Expected \(expected), got \(actual)."
        }
    }
}

struct ParsedLUT {
    let size: Int
    let rgbaFloatData: Data
}

enum LUTParser {
    static func parseCube(text: String) throws -> ParsedLUT {
        var size: Int?
        var values: [Float] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty || line.hasPrefix("#") || line.uppercased().hasPrefix("TITLE") {
                continue
            }

            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ")
                if parts.count >= 2 {
                    size = Int(parts[1])
                }
                continue
            }

            if line.uppercased().hasPrefix("DOMAIN_") || line.uppercased().hasPrefix("LUT_1D") {
                continue
            }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                values.append(contentsOf: [r, g, b, 1.0])
            }
        }

        guard let cubeSize = size else { throw LUTParserError.missingSize }

        let expectedEntries = cubeSize * cubeSize * cubeSize
        let actualEntries = values.count / 4
        guard expectedEntries == actualEntries else {
            throw LUTParserError.wrongEntryCount(expected: expectedEntries, actual: actualEntries)
        }

        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return ParsedLUT(size: cubeSize, rgbaFloatData: data)
    }

    static func parseCubeFile(at url: URL) throws -> ParsedLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseCube(text: text)
    }
}
