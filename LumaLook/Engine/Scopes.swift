import Foundation
import CoreImage
import CoreGraphics

/// Video scopes for the Grade Room: RGB waveform, RGB parade, vectorscope and
/// RGB histogram, rendered from the GRADED frame so the user reads the grade
/// they're actually shipping. Computed on a tiny downscaled bitmap on a
/// background task — cheap enough to refresh as sliders move.
enum ScopeMode: String, CaseIterable {
    case waveform, parade, vectorscope, histogram, falseColor
    var title: String {
        switch self {
        case .waveform: return "RGB WAVEFORM"
        case .parade: return "RGB PARADE"
        case .vectorscope: return "VECTORSCOPE"
        case .histogram: return "RGB HISTOGRAM"
        case .falseColor: return "FALSE COLOR"
        }
    }
    var next: ScopeMode {
        let all = ScopeMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum Scopes {

    static func render(frame: CIImage, state: LookState, mode: ScopeMode,
                       size: CGSize) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let graded = LookPipeline.shared.apply(state: state, to: frame, includeSplit: false)
            guard let pixels = sampleBitmap(graded) else { return nil }
            let w = max(32, Int(size.width)), h = max(24, Int(size.height))
            var acc = [Float](repeating: 0, count: w * h * 3)   // R,G,B additive
            if mode == .falseColor {
                return falseColorImage(pixels, w: w, h: h)
            }
            switch mode {
            case .waveform:   drawWaveform(pixels, into: &acc, w: w, h: h, parade: false)
            case .parade:     drawWaveform(pixels, into: &acc, w: w, h: h, parade: true)
            case .vectorscope: drawVectorscope(pixels, into: &acc, w: w, h: h)
            case .histogram:  drawHistogram(pixels, into: &acc, w: w, h: h)
            case .falseColor: break
            }
            return bitmap(from: acc, w: w, h: h,
                          graticule: mode == .vectorscope ? .vector : .grid)
        }.value
    }

    // MARK: analysis bitmap

    private struct Sampled { let px: [UInt8]; let w: Int; let h: Int }

    private static func sampleBitmap(_ image: CIImage) -> Sampled? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1,
              extent.width < 1e7, extent.height < 1e7 else { return nil }
        let aw = 160
        let ah = max(1, Int((Double(aw) * extent.height / extent.width).rounded()))
        let scale = CGFloat(aw) / extent.width
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -extent.minX * scale,
                                               y: -extent.minY * scale))
        var buf = [UInt8](repeating: 0, count: aw * ah * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        buf.withUnsafeMutableBytes { raw in
            LookPipeline.shared.context.render(
                scaled, toBitmap: raw.baseAddress!, rowBytes: aw * 4,
                bounds: CGRect(x: 0, y: 0, width: aw, height: ah),
                format: .RGBA8, colorSpace: space)
        }
        return Sampled(px: buf, w: aw, h: ah)
    }

    // MARK: scope draws

    private static func drawWaveform(_ s: Sampled, into acc: inout [Float],
                                     w: Int, h: Int, parade: Bool) {
        let colW = parade ? w / 3 : w
        for y in 0..<s.h {
            for x in 0..<s.w {
                let i = (y * s.w + x) * 4
                let r = Float(s.px[i]) / 255, g = Float(s.px[i + 1]) / 255, b = Float(s.px[i + 2]) / 255
                if parade {
                    plot(&acc, w: w, h: h, sx: (x * colW) / s.w, val: r, chan: 0, gain: 0.5)
                    plot(&acc, w: w, h: h, sx: colW + (x * colW) / s.w, val: g, chan: 1, gain: 0.5)
                    plot(&acc, w: w, h: h, sx: 2 * colW + (x * colW) / s.w, val: b, chan: 2, gain: 0.5)
                } else {
                    let sx = (x * w) / s.w
                    plot(&acc, w: w, h: h, sx: sx, val: r, chan: 0, gain: 0.42)
                    plot(&acc, w: w, h: h, sx: sx, val: g, chan: 1, gain: 0.42)
                    plot(&acc, w: w, h: h, sx: sx, val: b, chan: 2, gain: 0.42)
                }
            }
        }
    }

    private static func plot(_ acc: inout [Float], w: Int, h: Int, sx: Int, val: Float, chan: Int, gain: Float) {
        guard sx >= 0, sx < w else { return }
        let sy = min(h - 1, max(0, Int((1 - val) * Float(h - 1))))
        acc[(sy * w + sx) * 3 + chan] += gain
    }

    private static func drawVectorscope(_ s: Sampled, into acc: inout [Float], w: Int, h: Int) {
        let cx = Float(w) / 2, cy = Float(h) / 2
        let radius = Float(min(w, h)) / 2 * 0.92
        for y in 0..<s.h {
            for x in 0..<s.w {
                let i = (y * s.w + x) * 4
                let r = Float(s.px[i]) / 255, g = Float(s.px[i + 1]) / 255, b = Float(s.px[i + 2]) / 255
                let u = -0.169 * r - 0.331 * g + 0.5 * b
                let v = 0.5 * r - 0.419 * g - 0.081 * b
                let px = Int(cx + u * radius * 2.4)
                let py = Int(cy - v * radius * 2.4)
                guard px >= 0, px < w, py >= 0, py < h else { continue }
                let j = (py * w + px) * 3
                acc[j] += r * 0.5; acc[j + 1] += g * 0.5; acc[j + 2] += b * 0.5
            }
        }
    }

    private static func drawHistogram(_ s: Sampled, into acc: inout [Float], w: Int, h: Int) {
        let bins = w
        var hr = [Float](repeating: 0, count: bins)
        var hg = [Float](repeating: 0, count: bins)
        var hb = [Float](repeating: 0, count: bins)
        for y in 0..<s.h {
            for x in 0..<s.w {
                let i = (y * s.w + x) * 4
                hr[min(bins - 1, Int(Float(s.px[i]) / 255 * Float(bins - 1)))] += 1
                hg[min(bins - 1, Int(Float(s.px[i + 1]) / 255 * Float(bins - 1)))] += 1
                hb[min(bins - 1, Int(Float(s.px[i + 2]) / 255 * Float(bins - 1)))] += 1
            }
        }
        let peak = max(hr.max() ?? 1, hg.max() ?? 1, hb.max() ?? 1, 1)
        for x in 0..<bins {
            fillColumn(&acc, w: w, h: h, x: x, height: hr[x] / peak, chan: 0)
            fillColumn(&acc, w: w, h: h, x: x, height: hg[x] / peak, chan: 1)
            fillColumn(&acc, w: w, h: h, x: x, height: hb[x] / peak, chan: 2)
        }
    }

    private static func fillColumn(_ acc: inout [Float], w: Int, h: Int, x: Int, height: Float, chan: Int) {
        let top = Int((1 - min(1, height)) * Float(h - 1))
        for y in top..<h { acc[(y * w + x) * 3 + chan] += 0.5 }
    }

    // MARK: false colour (IRE exposure heat map)

    /// Recolours the frame by luma into an exposure ramp: blue (crushed) →
    /// green (mid/skin) → yellow → red (clipping). The fastest read on
    /// whether an exposure is safe.
    private static func falseColorImage(_ s: Sampled, w: Int, h: Int) -> CGImage? {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let sy = y * s.h / h
            for x in 0..<w {
                let sx = x * s.w / w
                let si = (sy * s.w + sx) * 4
                let luma = 0.2126 * Float(s.px[si]) / 255 + 0.7152 * Float(s.px[si + 1]) / 255 + 0.0722 * Float(s.px[si + 2]) / 255
                let (r, g, b) = ireColor(luma)
                let o = (y * w + x) * 4
                out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = 255
            }
        }
        return imageFromRGBA(out, w: w, h: h)
    }

    private static func ireColor(_ l: Float) -> (UInt8, UInt8, UInt8) {
        // Stops: 0 purple, .1 blue, .4 green, .5 grey, .7 pink, .9 yellow, 1 red.
        let stops: [(Float, (UInt8, UInt8, UInt8))] = [
            (0.00, (40, 0, 60)), (0.06, (0, 0, 200)), (0.20, (0, 160, 200)),
            (0.42, (0, 200, 0)), (0.50, (150, 150, 150)), (0.70, (230, 120, 160)),
            (0.90, (240, 220, 0)), (1.00, (255, 0, 0))]
        for i in 0..<(stops.count - 1) where l <= stops[i + 1].0 {
            let (l0, c0) = stops[i], (l1, c1) = stops[i + 1]
            let t = (l - l0) / max(1e-4, l1 - l0)
            return (lerp(c0.0, c1.0, t), lerp(c0.1, c1.1, t), lerp(c0.2, c1.2, t))
        }
        return stops.last!.1
    }
    private static func lerp(_ a: UInt8, _ b: UInt8, _ t: Float) -> UInt8 {
        UInt8(max(0, min(255, Float(a) + (Float(b) - Float(a)) * t)))
    }

    // MARK: rasterise

    private enum Graticule { case grid, vector }

    private static func bitmap(from acc: [Float], w: Int, h: Int, graticule: Graticule) -> CGImage? {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            for c in 0..<3 {
                // sqrt tone-map so sparse traces stay visible.
                let v = min(1, sqrt(acc[p * 3 + c]))
                out[p * 4 + c] = UInt8(v * 255)
            }
            out[p * 4 + 3] = 255
        }
        // Graticule overlay (dim).
        func setPix(_ x: Int, _ y: Int, _ lum: UInt8) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 4
            for c in 0..<3 { out[i + c] = max(out[i + c], lum) }
        }
        switch graticule {
        case .grid:
            for i in 1..<4 {
                let gy = i * h / 4, gx = i * w / 4
                for x in stride(from: 0, to: w, by: 2) { setPix(x, gy, 34) }
                for y in stride(from: 0, to: h, by: 2) { setPix(gx, y, 22) }
            }
        case .vector:
            let cx = w / 2, cy = h / 2
            let rad = Double(min(w, h)) / 2 * 0.9
            for a in stride(from: 0.0, to: 360.0, by: 3) {
                let rr = a * .pi / 180
                setPix(cx + Int(cos(rr) * rad), cy + Int(sin(rr) * rad), 40)
            }
            // Skin-tone (I) line at ~123°.
            let sk = 123.0 * .pi / 180
            for t in stride(from: 0.0, to: rad, by: 1) {
                setPix(cx + Int(cos(sk) * t), cy - Int(sin(sk) * t), 55)
            }
        }
        return imageFromRGBA(out, w: w, h: h)
    }

    private static func imageFromRGBA(_ data: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
