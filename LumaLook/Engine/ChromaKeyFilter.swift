import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Green/blue-screen keying via a cached `CIColorCube`: colours dominated by
/// the key channel go transparent with a softness ramp, and residual spill on
/// the kept fringe is suppressed. Pure function of the params → cacheable, GPU-
/// fast, identical in preview and export.
enum ChromaKeyFilter {
    private static let lock = NSLock()
    private static var cache: [String: CIColorCube] = [:]
    private static let cubeSize = 64

    static func apply(to image: CIImage, settings: ChromaKeySettings) -> CIImage {
        let key = "\(settings.colorHex)|\(settings.tolerance)|\(settings.softness)"
        lock.lock()
        let cube: CIColorCube
        if let cached = cache[key] {
            cube = cached
        } else {
            cube = makeCube(settings)
            cache[key] = cube
        }
        lock.unlock()
        cube.inputImage = image
        return (cube.outputImage ?? image).cropped(to: image.extent)
    }

    /// Builds a colour cube that zeroes alpha where the key channel dominates.
    private static func makeCube(_ settings: ChromaKeySettings) -> CIColorCube {
        let n = cubeSize
        let (kr, kg, kb) = rgb(from: settings.colorHex)
        // Which channel is the key? (green screen → green, blue → blue.)
        let dominant: Int = (kg >= kr && kg >= kb) ? 1 : (kb >= kr && kb >= kg ? 2 : 0)
        let lo = Float(settings.tolerance - settings.softness)
        let hi = Float(settings.tolerance + settings.softness)

        var data = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        for bi in 0..<n {
            let b = Float(bi) / Float(n - 1)
            for gi in 0..<n {
                let g = Float(gi) / Float(n - 1)
                for ri in 0..<n {
                    let r = Float(ri) / Float(n - 1)
                    // Keyness: dominance of the key channel over the other two.
                    let keyness: Float
                    switch dominant {
                    case 1:  keyness = g - max(r, b)
                    case 2:  keyness = b - max(r, g)
                    default: keyness = r - max(g, b)
                    }
                    // alpha = 1 outside the key, 0 inside, smooth between.
                    let alpha = 1 - smoothstep(lo, hi, keyness)
                    // Spill suppression on the kept fringe: pull the key channel
                    // down to the max of the other two.
                    var rr = r, gg = g, bb = b
                    if alpha > 0.01 {
                        switch dominant {
                        case 1:  gg = min(gg, max(rr, bb))
                        case 2:  bb = min(bb, max(rr, gg))
                        default: rr = min(rr, max(gg, bb))
                        }
                    }
                    // CIColorCube expects PREMULTIPLIED RGBA.
                    data[offset + 0] = rr * alpha
                    data[offset + 1] = gg * alpha
                    data[offset + 2] = bb * alpha
                    data[offset + 3] = alpha
                    offset += 4
                }
            }
        }

        let filter = CIFilter.colorCube()
        filter.cubeDimension = Float(n)
        filter.cubeData = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return filter
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 0.0001), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func rgb(from hex: String) -> (Float, Float, Float) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 1, 0) }
        return (Float((v >> 16) & 0xFF) / 255,
                Float((v >> 8) & 0xFF) / 255,
                Float(v & 0xFF) / 255)
    }
}
