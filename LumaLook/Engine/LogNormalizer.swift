import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// T2.8 — built-in log normalization. Per profile, a 33³ cube computed from
/// the PUBLIC transfer math: linearize (decode curve) → native-gamut→Rec.709
/// matrix (clamped) → filmic display render. No vendor .cube files shipped
/// (licensing); the math is published by each vendor.
///
/// The cube is applied as a PLAIN `CIColorCube` on raw code values — never
/// through `colorCubeWithColorSpace`, which would "helpfully" linearize the
/// log signal first and wreck the decode.
///
/// The render step is a filmic S-curve, NOT the bare inverse-OETF — flat
/// washed-out log output is the #1 reviewer gripe this feature answers.
enum LogProfile: String, CaseIterable, Codable {
    case appleLog, slog3, vlog, dlog, hlg

    var label: String {
        switch self {
        case .appleLog: return "Apple Log"
        case .slog3:    return "S-Log3"
        case .vlog:     return "V-Log"
        case .dlog:     return "D-Log"
        case .hlg:      return "HLG"
        }
    }
}

enum LogNormalizer {

    private static let lock = NSLock()
    private static var cache: [LogProfile: CIFilter] = [:]

    /// Applies the profile's normalization cube, dissolved by `opacity`.
    static func apply(_ profile: LogProfile, to image: CIImage,
                      opacity: Double = 1.0) -> CIImage {
        guard let filter = cubeFilter(for: profile) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        guard let out = filter.value(forKey: kCIOutputImageKey) as? CIImage else { return image }
        let mix = min(max(opacity, 0), 1)
        guard mix < 0.999 else { return out }
        return out.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - mix,
        ]).cropped(to: image.extent)
    }

    private static func cubeFilter(for profile: LogProfile) -> CIFilter? {
        lock.lock()
        if let hit = cache[profile] { lock.unlock(); return hit.copy() as? CIFilter }
        lock.unlock()

        let n = 33
        var data = [Float](repeating: 0, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let code = (Double(r) / Double(n - 1),
                        Double(g) / Double(n - 1),
                        Double(b) / Double(n - 1))
            var lin = (decode(profile, code.0), decode(profile, code.1), decode(profile, code.2))
            lin = gamutTo709(profile, lin)
            if profile == .hlg {
                // HLG OOTF: system gamma on luminance (simplified per-signal).
                let y = 0.2627 * lin.0 + 0.6780 * lin.1 + 0.0593 * lin.2
                let boost = pow(max(y, 1e-6), 0.2)   // γ=1.2 → Y^(γ-1)
                lin = (lin.0 * boost, lin.1 * boost, lin.2 * boost)
            }
            let out = (render(lin.0), render(lin.1), render(lin.2))
            let i = ((b * n + g) * n + r) * 4
            data[i] = Float(out.0); data[i + 1] = Float(out.1)
            data[i + 2] = Float(out.2); data[i + 3] = 1
        }}}

        let filter = CIFilter.colorCube()
        filter.cubeDimension = Float(n)
        filter.cubeData = data.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        cache[profile] = filter
        lock.unlock()
        return filter.copy() as? CIFilter
    }

    // MARK: - Decode curves (code value 0…1 → scene-linear, 0.18 = mid grey)

    /// Public vendor math; each cited in comments. Internal so the numeric
    /// harness can drive them directly.
    static func decode(_ profile: LogProfile, _ x: Double) -> Double {
        switch profile {
        case .appleLog:
            // Apple Log Profile White Paper (2023).
            let R0 = -0.05641088, Rt = 0.01
            let c = 47.28711236, beta = 0.00964052
            let gamma = 0.08550479, delta = 0.69336945
            let Pt = c * (Rt - R0) * (Rt - R0)
            if x >= Pt { return pow(2, (x - delta) / gamma) - beta }
            if x >= 0 { return R0 + (x / c).squareRoot() }
            return R0
        case .slog3:
            // Sony S-Log3 technical summary.
            if x >= 171.2102946929 / 1023.0 {
                return pow(10, (x * 1023.0 - 420.0) / 261.5) * 0.19 - 0.01
            }
            return (x * 1023.0 - 95.0) * 0.01125 / (171.2102946929 - 95.0)
        case .vlog:
            // Panasonic V-Log/V-Gamut reference.
            let b = 0.00873, c = 0.241514, d = 0.598206
            if x <= 0.181 { return (x - 0.125) / 5.6 }
            return pow(10, (x - d) / c) - b
        case .dlog:
            // DJI D-Log whitepaper.
            if x <= 0.14 { return (x - 0.0929) / 6.025 }
            return (pow(10, 3.89616 * x - 2.27752) - 0.0108) / 0.9892
        case .hlg:
            // ITU-R BT.2100 HLG inverse OETF (signal → scene linear 0…1).
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            if x <= 0.5 { return (x * x) / 3.0 }
            return (exp((x - c) / a) + b) / 12.0
        }
    }

    // MARK: - Gamut → Rec.709

    /// Native camera gamut → Rec.709 3×3 (row-major), negatives clamped.
    /// Matrices are the commonly published values; flagged in the plan for a
    /// vendor-reference spot-check (S-Gamut3.Cine and D-Gamut least certain).
    static func gamutTo709(_ profile: LogProfile, _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        let m: [Double]
        switch profile {
        case .appleLog, .hlg:
            // Rec.2020 → Rec.709 (BT.2087).
            m = [1.6605, -0.5876, -0.0728,
                 -0.1246, 1.1329, -0.0083,
                 -0.0182, -0.1006, 1.1187]
        case .slog3:
            // S-Gamut3.Cine → Rec.709.
            m = [1.6410, -0.5245, -0.1165,
                 -0.1103, 1.2015, -0.0912,
                 -0.0024, -0.1231, 1.1255]
        case .vlog:
            // V-Gamut → Rec.709.
            m = [1.5060, -0.4159, -0.0901,
                 -0.1002, 1.1477, -0.0475,
                 -0.0043, -0.1000, 1.1043]
        case .dlog:
            // D-Gamut → Rec.709.
            m = [1.5433, -0.4809, -0.0624,
                 -0.1123, 1.1687, -0.0564,
                 -0.0091, -0.1029, 1.1120]
        }
        let r = max(0, m[0] * v.0 + m[1] * v.1 + m[2] * v.2)
        let g = max(0, m[3] * v.0 + m[4] * v.1 + m[5] * v.2)
        let b = max(0, m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
        return (r, g, b)
    }

    // MARK: - Display render (filmic S-curve, monotone cubic)

    /// Scene-linear → display, through the plan's anchor points
    /// (0,0)(0.18,0.46)(0.5,0.72)(0.75,0.86)(1,0.95) with a soft shoulder to
    /// 1.0 above scene-linear 1. Mid-grey 0.18 lands at ~0.46 — the Rec.709
    /// convention — so log footage reads like footage, not porridge.
    static func render(_ linear: Double) -> Double {
        let x = max(0, linear)
        // Shoulder: everything above 1.0 compresses asymptotically to 1.
        if x >= 1 { return min(1, 0.95 + 0.05 * (1 - exp(-(x - 1) * 2))) }
        // Monotone piecewise-cubic through the anchors (precomputed tangents).
        let xs = [0.0, 0.18, 0.5, 0.75, 1.0]
        let ys = [0.0, 0.46, 0.72, 0.86, 0.95]
        // Fritsch–Carlson tangents for these fixed anchors.
        let ms = [2.5556, 1.5218, 0.6893, 0.4172, 0.36]
        var i = xs.count - 2
        for k in 0..<(xs.count - 1) where x < xs[k + 1] { i = k; break }
        let h = xs[i + 1] - xs[i]
        let t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        return min(1, max(0, h00 * ys[i] + h10 * h * ms[i] + h01 * ys[i + 1] + h11 * h * ms[i + 1]))
    }
}
