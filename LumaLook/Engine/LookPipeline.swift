import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Describes the currently selected grade. Reference type so a live
/// AVVideoComposition frame handler always reads the latest values
/// without rebuilding the composition.
final class LookState: @unchecked Sendable {
    private let lock = NSLock()

    private var _recipe: LookRecipe = LookRecipe()
    private var _settings: LookSettings = LookSettings()
    private var _lut: ParsedLUT?
    private var _lutOpacity: Double = 1.0
    private var _conversionLUT: ParsedLUT?
    private var _conversionOpacity: Double = 1.0
    private var _splitFraction: Double?

    var recipe: LookRecipe {
        get { lock.lock(); defer { lock.unlock() }; return _recipe }
        set { lock.lock(); _recipe = newValue; lock.unlock() }
    }

    var settings: LookSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    var lut: ParsedLUT? {
        get { lock.lock(); defer { lock.unlock() }; return _lut }
        set { lock.lock(); _lut = newValue; lock.unlock() }
    }

    /// Creative slot opacity (0…1): blends the creative LUT with its input.
    var lutOpacity: Double {
        get { lock.lock(); defer { lock.unlock() }; return _lutOpacity }
        set { lock.lock(); _lutOpacity = newValue; lock.unlock() }
    }

    /// Slot 1 — technical/conversion LUT (e.g. AppleLog → Rec.709), applied
    /// BEFORE the creative look. The PeekLut/Lutter stacking model.
    var conversionLUT: ParsedLUT? {
        get { lock.lock(); defer { lock.unlock() }; return _conversionLUT }
        set { lock.lock(); _conversionLUT = newValue; lock.unlock() }
    }

    var conversionOpacity: Double {
        get { lock.lock(); defer { lock.unlock() }; return _conversionOpacity }
        set { lock.lock(); _conversionOpacity = newValue; lock.unlock() }
    }

    /// Before/After wipe position (0…1). nil = full grade. Preview only —
    /// export passes includeSplit: false so the wipe is never baked in.
    var splitFraction: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _splitFraction }
        set { lock.lock(); _splitFraction = newValue; lock.unlock() }
    }
}

final class LookPipeline: @unchecked Sendable {
    static let shared = LookPipeline()

    /// Shared Metal-backed context per the technical architecture spec.
    let context = CIContext(options: [.useSoftwareRenderer: false])

    private var lutDataCache: [URL: ParsedLUT] = [:]
    private let cacheLock = NSLock()

    // MARK: - LUT loading with cache

    func loadLUT(at url: URL) throws -> ParsedLUT {
        cacheLock.lock()
        if let cached = lutDataCache[url] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let parsed = try LUTParser.parseCubeFile(at: url)
        cacheLock.lock()
        lutDataCache[url] = parsed
        cacheLock.unlock()
        return parsed
    }

    // MARK: - Main entry point

    /// Applies the full look (LUT or built-in recipe + user settings) to a frame,
    /// blending with the original by `settings.intensity`.
    func apply(state: LookState, to image: CIImage, includeSplit: Bool = true) -> CIImage {
        let settings = state.settings
        var graded = image

        // Slot 1 — conversion (log normalisation), blended by slot opacity.
        if let conversion = state.conversionLUT {
            graded = applyLUT(conversion, to: graded, opacity: state.conversionOpacity)
        }

        // Slot 2 — creative: imported LUT or built-in recipe.
        if let lut = state.lut {
            graded = applyLUT(lut, to: graded, opacity: state.lutOpacity)
        } else {
            graded = applyRecipe(state.recipe, to: graded)
        }

        graded = applyUserAdjustments(settings, to: graded)

        // Intensity blend: dissolve between original and graded frame.
        let intensity = min(max(settings.intensity / 100.0, 0), 1)
        if intensity < 0.999 {
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = image
            dissolve.targetImage = graded
            dissolve.time = Float(intensity)
            graded = dissolve.outputImage ?? graded
        }

        // Lens simulation: PHYSICAL glass, applied after the grade and
        // outside the intensity blend — dialling a look down doesn't
        // remove the lens the footage was "shot" through.
        if let lens = LensKind(rawValue: settings.lensKind), lens != .none {
            graded = applyLens(lens, amount: settings.lensAmount / 100.0, to: graded)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_SEED_DEBUG"] == "1" {
            print("[LUMA] apply lens=\(settings.lensKind) amount=\(settings.lensAmount)")
        }
        #endif

        // Before/After wipe: original left of the divider, graded right.
        if includeSplit, let fraction = state.splitFraction {
            let extent = image.extent
            let splitX = extent.minX + extent.width * CGFloat(min(max(fraction, 0), 1))
            let gradedRight = graded.cropped(to: CGRect(x: splitX, y: extent.minY,
                                                        width: extent.maxX - splitX,
                                                        height: extent.height))
            graded = gradedRight.composited(over: image)
        }

        return graded.cropped(to: image.extent)
    }

    // MARK: - Lens simulation (medium transformation)

    /// Optical character of real glass, built from Core Image primitives.
    /// All spatial — never part of cube bakes (like grain/bloom/vignette).
    func applyLens(_ kind: LensKind, amount: Double, to image: CIImage) -> CIImage {
        let a = CGFloat(min(max(amount, 0), 1))
        guard a > 0.01 else { return image }
        let extent = image.extent
        guard extent.width > 4, extent.height > 4, !extent.isInfinite else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)

        switch kind {
        case .none:
            return image

        case .anamorphic:
            // Blue horizontal streak flares: crushed highlights, stretched
            // wide, tinted scope-blue, screened back over the frame.
            let highlights = image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0),
                    "inputBiasVector": CIVector(x: -2.2, y: -2.2, z: -2.2, w: 0),
                ])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ])
            let streak = highlights.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: 14 + extent.width * 0.045 * a,
                    kCIInputAngleKey: 0,
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.25 * a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.45 * a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.0 * a, w: 0),
                ])
                .cropped(to: extent)
            return streak.applyingFilter("CIScreenBlendMode",
                                         parameters: [kCIInputBackgroundImageKey: image])
                .cropped(to: extent)

        case .vintage:
            // Chromatic aberration: red plane grows, blue shrinks about the
            // centre — fringing that widens toward the corners — plus the
            // heavy falloff old coatings couldn't avoid.
            func plane(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, scale: CGFloat) -> CIImage {
                var out = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                ])
                if abs(scale - 1) > 0.0001 {
                    out = out.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                }
                return out.cropped(to: extent)
            }
            let shift = 0.006 * a
            let combined = plane(1, 0, 0, scale: 1 + shift)
                .applyingFilter("CIAdditionCompositing",
                                parameters: [kCIInputBackgroundImageKey: plane(0, 1, 0, scale: 1)])
                .applyingFilter("CIAdditionCompositing",
                                parameters: [kCIInputBackgroundImageKey: plane(0, 0, 1, scale: 1 - shift)])
            return combined.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 1.4 * a,
                kCIInputRadiusKey: 2.2,
            ]).cropped(to: extent)

        case .diffusion:
            // Pro-mist: soft glow screened over the frame + a gentle lift.
            let glow = image.clampedToExtent()
                .applyingGaussianBlur(sigma: 8 + 22 * a)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.75 * a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.75 * a, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.75 * a, w: 0),
                ])
                .cropped(to: extent)
            return glow.applyingFilter("CIScreenBlendMode",
                                       parameters: [kCIInputBackgroundImageKey: image])
                .cropped(to: extent)

        case .fisheye:
            // Barrel bulge about the centre, cropped back to frame.
            return image.clampedToExtent()
                .applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                    kCIInputRadiusKey: max(extent.width, extent.height) * 0.75,
                    kCIInputScaleKey: 0.55 * a,
                ])
                .cropped(to: extent)

        case .swirl:
            // Vintage Soviet-prime character: the field rotates gently around
            // the subject while the centre stays planted.
            let swirled = image.clampedToExtent()
                .applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                    kCIInputRadiusKey: max(extent.width, extent.height) * 0.85,
                    kCIInputAngleKey: 0.45 * a,
                ])
                .cropped(to: extent)
            return swirled.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 0.8 * a,
                kCIInputRadiusKey: 2.4,
            ]).cropped(to: extent)

        case .plastic:
            // Toy camera: popped saturation, crushed corner falloff, and a
            // cheap-lens softness ramp toward the edges.
            let popped = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + 0.35 * a,
                kCIInputContrastKey: 1 + 0.12 * a,
            ])
            let radial = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                "inputRadius0": min(extent.width, extent.height) * 0.30,
                "inputRadius1": max(extent.width, extent.height) * 0.72,
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white,
            ])?.outputImage ?? CIImage(color: .black)
            let soft = popped.clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": radial.cropped(to: extent),
                    kCIInputRadiusKey: 9 * a,
                ])
                .cropped(to: extent)
            return soft.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 1.8 * a,
                kCIInputRadiusKey: 1.9,
            ]).cropped(to: extent)

        case .tiltShift:
            // Miniature: a razor focus band across the middle, blur ramping
            // toward top and bottom via a masked variable blur.
            let bandTop = extent.minY + extent.height * 0.62
            let bandBottom = extent.minY + extent.height * 0.38
            let topMask = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x, y: bandTop),
                "inputPoint1": CIVector(x: center.x, y: extent.maxY),
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white,
            ])?.outputImage ?? CIImage(color: .black)
            let bottomMask = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x, y: bandBottom),
                "inputPoint1": CIVector(x: center.x, y: extent.minY),
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white,
            ])?.outputImage ?? CIImage(color: .black)
            let mask = topMask.applyingFilter("CIAdditionCompositing",
                                              parameters: [kCIInputBackgroundImageKey: bottomMask])
                .cropped(to: extent)
            return image.clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": mask,
                    kCIInputRadiusKey: 14 * a,
                ])
                .cropped(to: extent)
        }
    }

    // MARK: - LUT application

    func applyLUT(_ lut: ParsedLUT, to image: CIImage, opacity: Double = 1.0) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(lut.size)
        filter.cubeData = lut.rgbaFloatData
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let out = filter.outputImage ?? image
        let mix = min(max(opacity, 0), 1)
        guard mix < 0.999 else { return out }
        // Per-slot opacity: dissolve the slot's output with its own input.
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = out
        dissolve.time = Float(mix)
        return dissolve.outputImage ?? out
    }

    // MARK: - Built-in look recipes

    func applyRecipe(_ recipe: LookRecipe, to image: CIImage) -> CIImage {
        var output = image

        if recipe.temperature != 6500 || recipe.tint != 0 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: CGFloat(recipe.temperature), y: CGFloat(recipe.tint))
            temp.targetNeutral = CIVector(x: 6500, y: 0)
            output = temp.outputImage ?? output
        }

        if recipe.contrast != 1 || recipe.saturation != 1 || recipe.brightness != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = recipe.contrast
            controls.saturation = recipe.saturation
            controls.brightness = recipe.brightness
            output = controls.outputImage ?? output
        }

        if recipe.bloom > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output.clampedToExtent()
            bloom.intensity = recipe.bloom
            bloom.radius = 8
            output = bloom.outputImage?.cropped(to: image.extent) ?? output
        }

        if recipe.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = output
            vignette.intensity = recipe.vignette
            vignette.radius = 2.0
            output = vignette.outputImage ?? output
        }

        return output
    }

    // MARK: - User slider adjustments on top of the look

    private func applyUserAdjustments(_ settings: LookSettings, to image: CIImage) -> CIImage {
        var output = image

        let hasColourChange = settings.exposure != 0 || settings.contrast != 10 || settings.saturation != 0
        if hasColourChange {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = Float(1.0 + (settings.contrast - 10) / 200.0)
            controls.saturation = Float(1.0 + settings.saturation / 100.0)
            controls.brightness = Float(settings.exposure / 300.0)
            output = controls.outputImage ?? output
        }

        if settings.warmth != 0 || settings.tint != 0 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500 - CGFloat(settings.warmth) * 20, y: CGFloat(settings.tint))
            temp.targetNeutral = CIVector(x: 6500, y: 0)
            output = temp.outputImage ?? output
        }

        // Pro colour surfaces (Grade Room): curves + wheels fold into one
        // separable cube; HSL is its own hue-aware cube. Both are pure colour,
        // so they bake cleanly into exported LUTs.
        if let transfer = ColorMath.transferCube(curves: settings.curves, wheels: settings.wheels) {
            transfer.setValue(output, forKey: kCIInputImageKey)
            output = transfer.outputImage?.cropped(to: image.extent) ?? output
        }
        if let hslCube = ColorMath.hslCube(settings.hsl) {
            hslCube.setValue(output, forKey: kCIInputImageKey)
            output = hslCube.outputImage?.cropped(to: image.extent) ?? output
        }

        if settings.bloom > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output.clampedToExtent()
            bloom.intensity = Float(settings.bloom / 100.0)
            bloom.radius = 10
            output = bloom.outputImage?.cropped(to: image.extent) ?? output
        }

        if settings.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = output
            vignette.intensity = Float(settings.vignette / 100.0 * 1.5)
            vignette.radius = 2.0
            output = vignette.outputImage ?? output
        }

        // Highlights / shadows: shadow lift-crush via highlightShadowAdjust,
        // highlight energy via a gentle tone-curve shoulder.
        if settings.shadows != 0 || settings.highlights < 0 {
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = output
            hs.shadowAmount = Float(settings.shadows / 100.0)
            // Negative highlights = recovery (industry convention).
            hs.highlightAmount = Float(1.0 + min(0, settings.highlights) / 100.0 * 0.7)
            hs.radius = 1.5
            output = hs.outputImage ?? output
        }

        if settings.highlights > 0 || settings.fade > 0 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            let lift = CGFloat(settings.fade / 100.0 * 0.12)
            let shoulder = CGFloat(0.8 + settings.highlights / 100.0 * 0.13)
            curve.point0 = CGPoint(x: 0, y: lift)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 + lift * 0.5)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.8, y: min(0.98, shoulder))
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }

        if settings.sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = output
            sharpen.sharpness = Float(settings.sharpness / 100.0 * 0.9)
            output = sharpen.outputImage?.cropped(to: image.extent) ?? output
        }

        if settings.halation > 0 {
            output = applyHalation(strength: settings.halation / 100.0, to: output)
        }

        if settings.grain > 0 {
            output = applyGrain(strength: settings.grain / 100.0, to: output)
        }

        return output
    }

    // MARK: - Film physics

    /// Halation: film's red-orange glow around bright highlights (light
    /// bouncing off the base layer back through the red-sensitive emulsion).
    /// Isolate highlights → blur wide → tint warm → screen back over.
    func applyHalation(strength: Double, to image: CIImage) -> CIImage {
        // 1. Highlight mask: keep only near-white energy.
        let threshold = CIFilter.colorMatrix()
        threshold.inputImage = image
        let gain: CGFloat = 2.2
        threshold.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        threshold.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        threshold.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        threshold.biasVector = CIVector(x: -1.35, y: -1.35, z: -1.35, w: 0)
        guard let highlights = threshold.outputImage else { return image }

        // 2. Wide soft blur, scaled with image size so it looks the same in
        //    thumbnails and 4K exports.
        let radius = max(image.extent.width, image.extent.height) * 0.012 * (0.6 + strength)
        let blurred = highlights
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: image.extent)

        // 3. Warm red-orange tint — the halation signature.
        let tint = CIFilter.colorMatrix()
        tint.inputImage = blurred
        tint.rVector = CIVector(x: CGFloat(1.0 * strength), y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: CGFloat(0.32 * strength), z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: CGFloat(0.08 * strength), w: 0)
        guard let glow = tint.outputImage else { return image }

        // 4. Screen blend back over the frame.
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = glow
        screen.backgroundImage = image
        return screen.outputImage?.cropped(to: image.extent) ?? image
    }

    /// Film grain: luminance-only noise, softened a touch, overlay-blended
    /// so it lives in the midtones like silver halide — not RGB confetti.
    func applyGrain(strength: Double, to image: CIImage) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }

        // Monochrome the noise and centre it on mid-grey for overlay blend.
        let mono = CIFilter.colorMatrix()
        // Slightly coarser than 1:1 pixels so it reads as grain, not sensor noise.
        mono.inputImage = noise.transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.6))
        let amp = CGFloat(0.28 * strength)
        mono.rVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        mono.gVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        mono.bVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 1)
        guard let grainField = mono.outputImage?
            .applyingGaussianBlur(sigma: 0.4)
            .cropped(to: image.extent) else { return image }

        let overlay = CIFilter.overlayBlendMode()
        overlay.inputImage = grainField
        overlay.backgroundImage = image
        return overlay.outputImage?.cropped(to: image.extent) ?? image
    }

    func renderCGImage(from image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    /// Grades a still image, optionally downscaled for interactive preview.
    func gradedStill(_ source: CIImage, state: LookState,
                     maxDimension: CGFloat? = nil, includeSplit: Bool = false) -> CGImage? {
        var input = source
        if let maxDimension {
            let longest = max(input.extent.width, input.extent.height)
            if longest > maxDimension {
                let scale = maxDimension / longest
                input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let graded = apply(state: state, to: input, includeSplit: includeSplit)
            .cropped(to: input.extent)
        return context.createCGImage(graded, from: graded.extent,
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
