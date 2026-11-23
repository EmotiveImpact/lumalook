import Foundation

/// T2.5 — tetrahedral pre-upsampling. A coarse LUT (17³/33³) is resampled
/// once, at load, to a dense 64³ using the canonical 6-tetrahedron barycentric
/// decomposition — the interpolation colour scientists mean by "tetrahedral".
/// The runtime path stays the unchanged trilinear `colorCubeWithColorSpace`,
/// which over a dense grid carries ~¼ of the residual error: nearly all of
/// the visible tetra win (smooth skin/sky ramps, no banding steps) with zero
/// render-graph change, so preview == export is preserved automatically.
extension ParsedLUT {

    /// Resamples to `target`³ with tetrahedral interpolation. Returns self if
    /// already at/above the target (never downsample — that loses detail).
    func densifiedTetrahedral(to target: Int) -> ParsedLUT {
        guard size < target, size >= 2 else { return self }

        // Source floats: r-fastest RGBA, index = ((b·N + g)·N + r)·4.
        let src: [Float] = rgbaFloatData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let n = size
        guard src.count >= n * n * n * 4 else { return self }

        @inline(__always) func sample(_ r: Int, _ g: Int, _ b: Int) -> (Float, Float, Float) {
            let i = ((b * n + g) * n + r) * 4
            return (src[i], src[i + 1], src[i + 2])
        }

        var out = [Float](repeating: 0, count: target * target * target * 4)
        let scale = Float(n - 1) / Float(target - 1)

        for bt in 0..<target {
            let fb = Float(bt) * scale
            let b0 = min(Int(fb), n - 2), db = fb - Float(b0)
            for gt in 0..<target {
                let fg = Float(gt) * scale
                let g0 = min(Int(fg), n - 2), dg = fg - Float(g0)
                for rt in 0..<target {
                    let fr = Float(rt) * scale
                    let r0 = min(Int(fr), n - 2), dr = fr - Float(r0)

                    // Canonical 6-tetra decomposition of the unit cube: pick
                    // the tetrahedron by ordering (dr, dg, db), interpolate
                    // barycentrically along its edge path from c000 to c111.
                    let c000 = sample(r0, g0, b0)
                    let c111 = sample(r0 + 1, g0 + 1, b0 + 1)
                    var rr, gg, bb: Float

                    if dr >= dg && dg >= db {
                        let cA = sample(r0 + 1, g0, b0)
                        let cB = sample(r0 + 1, g0 + 1, b0)
                        rr = (1 - dr) * c000.0 + (dr - dg) * cA.0 + (dg - db) * cB.0 + db * c111.0
                        gg = (1 - dr) * c000.1 + (dr - dg) * cA.1 + (dg - db) * cB.1 + db * c111.1
                        bb = (1 - dr) * c000.2 + (dr - dg) * cA.2 + (dg - db) * cB.2 + db * c111.2
                    } else if dr >= db && dg >= dr {   // dg ≥ dr ≥ db
                        let cA = sample(r0, g0 + 1, b0)
                        let cB = sample(r0 + 1, g0 + 1, b0)
                        rr = (1 - dg) * c000.0 + (dg - dr) * cA.0 + (dr - db) * cB.0 + db * c111.0
                        gg = (1 - dg) * c000.1 + (dg - dr) * cA.1 + (dr - db) * cB.1 + db * c111.1
                        bb = (1 - dg) * c000.2 + (dg - dr) * cA.2 + (dr - db) * cB.2 + db * c111.2
                    } else if dg >= db {               // dg ≥ db > dr
                        let cA = sample(r0, g0 + 1, b0)
                        let cB = sample(r0, g0 + 1, b0 + 1)
                        rr = (1 - dg) * c000.0 + (dg - db) * cA.0 + (db - dr) * cB.0 + dr * c111.0
                        gg = (1 - dg) * c000.1 + (dg - db) * cA.1 + (db - dr) * cB.1 + dr * c111.1
                        bb = (1 - dg) * c000.2 + (dg - db) * cA.2 + (db - dr) * cB.2 + dr * c111.2
                    } else if dr >= db {               // dr ≥ db > dg
                        // This case was missing: its colours fell through to
                        // the next one, whose weights go negative here, so a
                        // sixth of every cell was pushed past its own corners
                        // (up to 29 of 255 on the 13-point film cubes).
                        // tools/skin-test/check_truecolour.swift checks all six.
                        let cA = sample(r0 + 1, g0, b0)
                        let cB = sample(r0 + 1, g0, b0 + 1)
                        rr = (1 - dr) * c000.0 + (dr - db) * cA.0 + (db - dg) * cB.0 + dg * c111.0
                        gg = (1 - dr) * c000.1 + (dr - db) * cA.1 + (db - dg) * cB.1 + dg * c111.1
                        bb = (1 - dr) * c000.2 + (dr - db) * cA.2 + (db - dg) * cB.2 + dg * c111.2
                    } else if dr >= dg {               // db > dr ≥ dg
                        let cA = sample(r0, g0, b0 + 1)
                        let cB = sample(r0 + 1, g0, b0 + 1)
                        rr = (1 - db) * c000.0 + (db - dr) * cA.0 + (dr - dg) * cB.0 + dg * c111.0
                        gg = (1 - db) * c000.1 + (db - dr) * cA.1 + (dr - dg) * cB.1 + dg * c111.1
                        bb = (1 - db) * c000.2 + (db - dr) * cA.2 + (dr - dg) * cB.2 + dg * c111.2
                    } else {                            // db > dg > dr
                        let cA = sample(r0, g0, b0 + 1)
                        let cB = sample(r0, g0 + 1, b0 + 1)
                        rr = (1 - db) * c000.0 + (db - dg) * cA.0 + (dg - dr) * cB.0 + dr * c111.0
                        gg = (1 - db) * c000.1 + (db - dg) * cA.1 + (dg - dr) * cB.1 + dr * c111.1
                        bb = (1 - db) * c000.2 + (db - dg) * cA.2 + (dg - dr) * cB.2 + dr * c111.2
                    }

                    let o = ((bt * target + gt) * target + rt) * 4
                    out[o] = rr; out[o + 1] = gg; out[o + 2] = bb; out[o + 3] = 1
                }
            }
        }

        return ParsedLUT(size: target,
                         rgbaFloatData: out.withUnsafeBufferPointer { Data(buffer: $0) },
                         domainMin: domainMin, domainMax: domainMax,
                         bakedByLumalook: bakedByLumalook)
    }

    /// T2.6 — plain trilinear resample, used to DOWNSAMPLE oversized lattices
    /// (65³ cubes, HALD level-12) to the iOS-safe 64³ cap.
    func resampledTrilinear(to target: Int) -> ParsedLUT {
        guard size != target, size >= 2 else { return self }
        let src: [Float] = rgbaFloatData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = size
        guard src.count >= n * n * n * 4 else { return self }
        @inline(__always) func at(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Float {
            src[((b * n + g) * n + r) * 4 + c]
        }
        var out = [Float](repeating: 0, count: target * target * target * 4)
        let scale = Float(n - 1) / Float(target - 1)
        for bt in 0..<target { for gt in 0..<target { for rt in 0..<target {
            let fr = Float(rt) * scale, fg = Float(gt) * scale, fb = Float(bt) * scale
            let r0 = min(Int(fr), n - 2), g0 = min(Int(fg), n - 2), b0 = min(Int(fb), n - 2)
            let dr = fr - Float(r0), dg = fg - Float(g0), db = fb - Float(b0)
            let o = ((bt * target + gt) * target + rt) * 4
            for c in 0..<3 {
                let c00 = at(r0, g0, b0, c) * (1 - dr) + at(r0 + 1, g0, b0, c) * dr
                let c10 = at(r0, g0 + 1, b0, c) * (1 - dr) + at(r0 + 1, g0 + 1, b0, c) * dr
                let c01 = at(r0, g0, b0 + 1, c) * (1 - dr) + at(r0 + 1, g0, b0 + 1, c) * dr
                let c11 = at(r0, g0 + 1, b0 + 1, c) * (1 - dr) + at(r0 + 1, g0 + 1, b0 + 1, c) * dr
                out[o + c] = (c00 * (1 - dg) + c10 * dg) * (1 - db) + (c01 * (1 - dg) + c11 * dg) * db
            }
            out[o + 3] = 1
        }}}
        return ParsedLUT(size: target,
                         rgbaFloatData: out.withUnsafeBufferPointer { Data(buffer: $0) },
                         domainMin: domainMin, domainMax: domainMax,
                         bakedByLumalook: bakedByLumalook)
    }
}
