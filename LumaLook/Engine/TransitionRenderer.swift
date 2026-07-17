import CoreImage
import CoreImage.CIFilterBuiltins

/// Cross-transition blend maths, factored out of the compositor so the render
/// loop just calls `render(...)`. Every style is a pure function of the two
/// frames + progress, so preview and export match exactly. `progress` runs
/// 0→1 across the whole span; the outgoing frame is fully replaced by the
/// incoming frame by p=1.
enum TransitionRenderer {

    static func render(outgoing: CIImage, incoming: CIImage,
                       progress: CGFloat, style: TransitionStyle, rect: CGRect) -> CIImage {
        let p = min(max(progress, 0), 1)
        switch style {
        case .wipe:            return wipe(outgoing, incoming, p: p, rect: rect)
        case .slideLeft:       return slide(outgoing, incoming, p: p, rect: rect, dx: -1, dy: 0)
        case .slideRight:      return slide(outgoing, incoming, p: p, rect: rect, dx: 1, dy: 0)
        case .slideUp:         return slide(outgoing, incoming, p: p, rect: rect, dx: 0, dy: 1)
        case .slideDown:       return slide(outgoing, incoming, p: p, rect: rect, dx: 0, dy: -1)
        case .zoomIn:          return zoom(outgoing, incoming, p: p, rect: rect, zoomingIn: true)
        case .zoomOut:         return zoom(outgoing, incoming, p: p, rect: rect, zoomingIn: false)
        case .spin:            return spin(outgoing, incoming, p: p, rect: rect)
        case .glitch:          return glitch(outgoing, incoming, p: p, rect: rect)
        case .lumaWipe:        return lumaWipe(outgoing, incoming, p: p, rect: rect)
        default:               return dissolve(outgoing, incoming, p: p, rect: rect)
        }
    }

    // MARK: - Basic

    private static func dissolve(_ outgoing: CIImage, _ incoming: CIImage,
                                 p: CGFloat, rect: CGRect) -> CIImage {
        let d = CIFilter.dissolveTransition()
        d.inputImage = outgoing
        d.targetImage = incoming
        d.time = Float(p)
        return (d.outputImage ?? incoming).cropped(to: rect)
    }

    private static func wipe(_ outgoing: CIImage, _ incoming: CIImage,
                             p: CGFloat, rect: CGRect) -> CIImage {
        let feather = rect.width * 0.05
        let edge = (rect.width + feather) * p - feather / 2
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: edge + feather / 2, y: 0)
        gradient.point1 = CGPoint(x: edge - feather / 2, y: 0)
        gradient.color0 = .black
        gradient.color1 = .white
        let mask = (gradient.outputImage ?? CIImage(color: .white)).cropped(to: rect)
        return blend(incoming, over: outgoing, mask: mask, rect: rect)
    }

    // MARK: - Motion

    /// Push transition: incoming slides in from one edge while the outgoing is
    /// pushed out the opposite edge. `dx`/`dy` are the incoming entry direction
    /// (−1 = from the right for slideLeft, etc.).
    private static func slide(_ outgoing: CIImage, _ incoming: CIImage,
                              p: CGFloat, rect: CGRect, dx: CGFloat, dy: CGFloat) -> CIImage {
        let e = smoothstep(p)
        let w = rect.width, h = rect.height
        // Incoming starts fully off-screen on the entry side, ends at 0.
        let inX = dx * w * (1 - e)
        let inY = dy * h * (1 - e)
        // Outgoing pushed out the opposite way.
        let outX = -dx * w * e
        let outY = -dy * h * e
        let out = outgoing.transformed(by: CGAffineTransform(translationX: outX, y: outY))
        let inc = incoming.transformed(by: CGAffineTransform(translationX: inX, y: inY))
        return inc.composited(over: out).cropped(to: rect)
    }

    /// Zoom-and-fade cross. zoomIn: outgoing scales up + fades out while the
    /// incoming settles from slightly enlarged. zoomOut mirrors the scales.
    private static func zoom(_ outgoing: CIImage, _ incoming: CIImage,
                             p: CGFloat, rect: CGRect, zoomingIn: Bool) -> CIImage {
        let e = smoothstep(p)
        let outScale = zoomingIn ? (1 + 0.55 * e) : (1 - 0.35 * e)
        let inScale = zoomingIn ? (1.25 - 0.25 * e) : (1.6 - 0.6 * e)
        let out = scaleAboutCentre(outgoing, scale: outScale, rect: rect)
        let inc = scaleAboutCentre(incoming, scale: inScale, rect: rect)
        return dissolve(out, inc, p: e, rect: rect)
    }

    private static func spin(_ outgoing: CIImage, _ incoming: CIImage,
                             p: CGFloat, rect: CGRect) -> CIImage {
        let e = smoothstep(p)
        let out = rotateAboutCentre(scaleAboutCentre(outgoing, scale: 1 + 0.1 * e, rect: rect),
                                    radians: 0.6 * e, rect: rect)
        let inc = rotateAboutCentre(scaleAboutCentre(incoming, scale: 1 + 0.1 * (1 - e), rect: rect),
                                    radians: -0.6 * (1 - e), rect: rect)
        return dissolve(out, inc, p: e, rect: rect)
    }

    // MARK: - FX

    /// RGB channel-split + horizontal slice jitter, peaking at the midpoint.
    private static func glitch(_ outgoing: CIImage, _ incoming: CIImage,
                               p: CGFloat, rect: CGRect) -> CIImage {
        let env = sin(Double(p) * .pi)              // 0→1→0
        let base = p < 0.5 ? outgoing : incoming
        let shift = CGFloat(14 * env)

        let r = channel(base, keep: .r).transformed(by: CGAffineTransform(translationX: shift, y: 0))
        let g = channel(base, keep: .g)
        let b = channel(base, keep: .b).transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        var img = add(add(r, g), b).cropped(to: rect)

        // A couple of jittered horizontal bands.
        for k in 0..<3 {
            let yFrac = (sin(Double(p) * 37 + Double(k) * 2.1) * 0.5 + 0.5)
            let bandH = rect.height * 0.08
            let y = rect.minY + CGFloat(yFrac) * (rect.height - bandH)
            let bandRect = CGRect(x: rect.minX, y: y, width: rect.width, height: bandH)
            let offset = CGFloat((k % 2 == 0 ? 1 : -1)) * 30 * CGFloat(env)
            let band = img.cropped(to: bandRect)
                .transformed(by: CGAffineTransform(translationX: offset, y: 0))
            img = band.composited(over: img).cropped(to: rect)
        }
        return img
    }

    /// Reveal driven by the OUTGOING frame's luminance: dark areas reveal the
    /// incoming frame first, bright areas last (a filmic "burn" wipe).
    private static func lumaWipe(_ outgoing: CIImage, _ incoming: CIImage,
                                 p: CGFloat, rect: CGRect) -> CIImage {
        let f: CGFloat = 0.12
        let luma = channelLuma(outgoing)
        // alpha = clamp((p·(1+2f) − Y − f) / (2f)) → feathered threshold.
        let poly = CIFilter.colorPolynomial()
        poly.inputImage = luma
        let scale = 1.0 / (2 * f)
        let bias = (p * (1 + 2 * f) - f) / (2 * f)
        // alpha channel: out = Y·(−scale) + bias, clamped by blendWithMask.
        let coeffs = CIVector(x: bias, y: -scale, z: 0, w: 0)
        poly.redCoefficients = coeffs
        poly.greenCoefficients = coeffs
        poly.blueCoefficients = coeffs
        let mask = (poly.outputImage ?? luma).cropped(to: rect)
        return blend(incoming, over: outgoing, mask: mask, rect: rect)
    }

    // MARK: - Helpers

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func blend(_ image: CIImage, over background: CIImage,
                              mask: CIImage, rect: CGRect) -> CIImage {
        let b = CIFilter.blendWithMask()
        b.inputImage = image
        b.backgroundImage = background
        b.maskImage = mask
        return (b.outputImage ?? image).cropped(to: rect)
    }

    private static func scaleAboutCentre(_ image: CIImage, scale: CGFloat, rect: CGRect) -> CIImage {
        guard abs(scale - 1) > 0.001 else { return image }
        let cx = rect.midX, cy = rect.midY
        let t = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        return image.transformed(by: t)
    }

    private static func rotateAboutCentre(_ image: CIImage, radians: CGFloat, rect: CGRect) -> CIImage {
        guard abs(radians) > 0.001 else { return image }
        let cx = rect.midX, cy = rect.midY
        let t = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        return image.transformed(by: t)
    }

    private enum Chan { case r, g, b }

    private static func channel(_ image: CIImage, keep: Chan) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: keep == .r ? 1 : 0, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: keep == .g ? 1 : 0, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: keep == .b ? 1 : 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    private static func channelLuma(_ image: CIImage) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let y = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        m.rVector = y; m.gVector = y; m.bVector = y
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    private static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.additionCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage ?? a
    }
}
