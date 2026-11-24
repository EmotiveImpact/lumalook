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
    private var _lutBlend: LUTBlendMode = .normal
    private var _conversionLUT: ParsedLUT?
    private var _conversionOpacity: Double = 1.0
    private var _conversionProfile: LogProfile?
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

    /// Creative slot blend mode (Normal/Soft Light/Overlay/Screen).
    var lutBlend: LUTBlendMode {
        get { lock.lock(); defer { lock.unlock() }; return _lutBlend }
        set { lock.lock(); _lutBlend = newValue; lock.unlock() }
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

    /// T2.8 — built-in log profile. Mutually exclusive with `conversionLUT`
    /// (same slot); the UI enforces it, the pipeline prefers the profile.
    var conversionProfile: LogProfile? {
        get { lock.lock(); defer { lock.unlock() }; return _conversionProfile }
        set { lock.lock(); _conversionProfile = newValue; lock.unlock() }
    }

    /// Before/After wipe position (0…1). nil = full grade. Preview only —
    /// export passes includeSplit: false so the wipe is never baked in.
    var splitFraction: Double? {
        get { lock.lock(); defer { lock.unlock() }; return _splitFraction }
        set { lock.lock(); _splitFraction = newValue; lock.unlock() }
    }
}

/// Slot 1 of a look state on its own: what sits under every look (a log
/// profile, or a conversion LUT, and how much of it). A thumbnail, a Compare
/// cell or an exported cube has to carry it, or it is drawn from footage the
/// big picture never shows.
struct ConversionSlot: @unchecked Sendable {
    var lut: ParsedLUT?
    var opacity: Double = 1
    var profile: LogProfile?

    static let none = ConversionSlot()

    /// Changes whenever the slot would draw differently.
    var stamp: String {
        "\(profile?.rawValue ?? "")-\(opacity)-\(lut?.size ?? 0)-\(lut?.rgbaFloatData.hashValue ?? 0)"
    }
}

extension LookState {
    var conversionSlot: ConversionSlot {
        get { ConversionSlot(lut: conversionLUT, opacity: conversionOpacity, profile: conversionProfile) }
        set {
            conversionLUT = newValue.lut
            conversionOpacity = newValue.opacity
            conversionProfile = newValue.profile
        }
    }
}

final class LookPipeline: @unchecked Sendable {
    static let shared = LookPipeline()

    /// Shared Metal-backed context per the technical architecture spec.
    let context = CIContext(options: [.useSoftwareRenderer: false])

    private var lutDataCache: [URL: ParsedLUT] = [:]
    private let cacheLock = NSLock()

    // MARK: - LUT loading with cache

    /// Forget parsed cubes, after files were rewritten in place (installed
    /// recipe looks baked again for True Colour).
    func clearLUTCache() {
        cacheLock.lock()
        lutDataCache.removeAll()
        cacheLock.unlock()
    }

    func loadLUT(at url: URL) throws -> ParsedLUT {
        cacheLock.lock()
        if let cached = lutDataCache[url] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let parsed = try LUTParser.parseCubeFile(at: url)
        // T2.5: coarse grids get tetrahedrally pre-upsampled to a dense 64³
        // once here — the trilinear runtime path over the dense grid carries
        // nearly all the tetra accuracy with zero render-graph change.
        let dense = parsed.size < 48 ? parsed.densifiedTetrahedral(to: 64) : parsed
        cacheLock.lock()
        // Bound the cache: a dense 64³ is ~4.2 MB; six is plenty (creative +
        // conversion + a few recents). Unbounded, a LUT-browsing session
        // would pin hundreds of MB.
        if lutDataCache.count >= 6 { lutDataCache.removeAll() }
        lutDataCache[url] = dense
        cacheLock.unlock()
        return dense
    }

    // MARK: - Main entry point

    /// Per-overlay tone tweak (exposure/contrast/saturation/warmth), layered on
    /// top of the shared grade. Each value is roughly ±1 in user space.
    func applyOverlayAdjustments(_ a: OverlayAdjustments, to image: CIImage) -> CIImage {
        var out = image
        if a.exposure != 0 {
            let e = CIFilter.exposureAdjust()
            e.inputImage = out
            e.ev = Float(a.exposure)
            out = e.outputImage ?? out
        }
        if a.contrast != 0 || a.saturation != 0,
           let tone = TrueColour.toneFilter(contrast: Float(1 + a.contrast * 0.5),
                                            saturation: Float(1 + a.saturation), brightness: 0) {
            // True Colour tone, not CIColorControls (see TrueColour.swift).
            tone.setValue(out, forKey: kCIInputImageKey)
            out = tone.outputImage ?? out
        }
        if a.warmth != 0 {
            out = Self.shiftWhite(out, towards: 6500 - CGFloat(a.warmth) * 1500, tint: 0)
        }
        return out.cropped(to: image.extent)
    }

    /// Applies the full look (LUT or built-in recipe + user settings) to a frame,
    /// blending with the original by `settings.intensity`.
    func apply(state: LookState, to image: CIImage, includeSplit: Bool = true) -> CIImage {
        let settings = state.settings
        var graded = image

        // Slot 1 — conversion (log normalisation), blended by slot opacity.
        // Built-in profile wins; applied as a PLAIN cube on raw code values
        // (colorCubeWithColorSpace would mis-linearize the log signal).
        if let profile = state.conversionProfile {
            graded = LogNormalizer.apply(profile, to: graded,
                                         opacity: state.conversionOpacity)
        } else if let conversion = state.conversionLUT {
            graded = applyLUT(conversion, to: graded, opacity: state.conversionOpacity)
        }

        // Slot 2 — creative: imported LUT or built-in recipe.
        if let lut = state.lut {
            graded = applyLUT(lut, to: graded, opacity: state.lutOpacity, blend: state.lutBlend,
                              protectSkin: true)
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
    // MARK: - Sizes that follow the picture

    /// The long edge the big picture on the look screen is graded at
    /// (`gradedStill(maxDimension: 1400)`). Every blur, glow and grain size
    /// below is written for a picture this big.
    static let referenceEdge: CGFloat = 1400

    /// How much bigger or smaller this picture is than the reference. Glow,
    /// blur and grain used to be a fixed number of pixels, so the same
    /// setting was about twice as strong on a 220 pixel look tile as on the
    /// big picture, and nearly gone in a full-size export (Bloom at 50 moved
    /// a tile by 14 of 255, the big picture by 3 and a 4032 pixel export by
    /// 1). Sized against the picture, a tile is a small copy of the big
    /// picture and the export is a large one.
    static func sizeScale(_ extent: CGRect) -> CGFloat {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return 1 }
        return max(extent.width, extent.height) / referenceEdge
    }

    func applyLens(_ kind: LensKind, amount: Double, to image: CIImage) -> CIImage {
        let a = CGFloat(min(max(amount, 0), 1))
        guard a > 0.01 else { return image }
        let extent = image.extent
        guard extent.width > 4, extent.height > 4, !extent.isInfinite else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let scale = Self.sizeScale(extent)

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
                    kCIInputRadiusKey: 14 * scale + extent.width * 0.045 * a,
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
                .applyingGaussianBlur(sigma: (8 + 22 * a) * scale)
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
            // Through True Colour like every other contrast in the app:
            // CIColorControls works in linear light and crushed deep skin.
            var popped = image
            if let pop = TrueColour.toneFilter(contrast: Float(1 + 0.12 * a),
                                               saturation: Float(1 + 0.35 * a),
                                               brightness: 0) {
                pop.setValue(image, forKey: kCIInputImageKey)
                popped = pop.outputImage ?? image
            }
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
                    kCIInputRadiusKey: 9 * a * scale,
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
                    kCIInputRadiusKey: 14 * a * scale,
                ])
                .cropped(to: extent)
        }
    }

    // MARK: - LUT application

    /// `protectSkin` is for the creative slot only: with True Colour on, the
    /// LUT runs with the skin guard baked in (TrueColour.lutData). Never for
    /// the conversion slot, which must stay an exact log transform.
    func applyLUT(_ lut: ParsedLUT, to image: CIImage,
                  opacity: Double = 1.0, blend: LUTBlendMode = .normal,
                  protectSkin: Bool = false) -> CIImage {
        // T2.6 — DOMAIN remap: CIColorCube samples inputs over [0,1], so a
        // custom domain becomes a per-channel affine remap in front.
        var cubeInput = image
        if lut.hasCustomDomain {
            let sr = 1 / max(lut.domainMax.0 - lut.domainMin.0, 1e-4)
            let sg = 1 / max(lut.domainMax.1 - lut.domainMin.1, 1e-4)
            let sb = 1 / max(lut.domainMax.2 - lut.domainMin.2, 1e-4)
            cubeInput = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(sr), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(sg), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(sb), w: 0),
                "inputBiasVector": CIVector(x: CGFloat(-lut.domainMin.0 * sr),
                                            y: CGFloat(-lut.domainMin.1 * sg),
                                            z: CGFloat(-lut.domainMin.2 * sb), w: 0),
            ])
        }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = cubeInput
        filter.cubeDimension = Float(lut.size)
        filter.cubeData = protectSkin ? TrueColour.lutData(for: lut) : lut.rgbaFloatData
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        var out = filter.outputImage ?? image
        // Blend the LUT result over the slot's INPUT (so the original
        // luminance drives Overlay/Soft-Light) — the "adjustment layer" model.
        if let blendName = blend.ciName {
            out = out.applyingFilter(blendName, parameters: [kCIInputBackgroundImageKey: image])
                .cropped(to: image.extent)
        }
        let mix = min(max(opacity, 0), 1)
        guard mix < 0.999 else { return out }
        // Per-slot opacity: dissolve the slot's output with its own input.
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = out
        dissolve.time = Float(mix)
        return dissolve.outputImage ?? out
    }

    // MARK: - White balance

    /// Shifts `image` towards the colour of light at `kelvin`: below 6500 is
    /// warmer (golden hour is about 4900), above it cooler. `tint` keeps the
    /// meaning it has always had in recipes and settings.
    ///
    /// CITemperatureAndTint's `neutral` is the white of the light a picture
    /// was taken under, which the filter corrects to `targetNeutral`, so a
    /// 4900 K neutral takes warmth OUT. Every recipe temperature and warmth
    /// slider here means the light the look should have, and used to sit in
    /// `neutral`: Golden Hour rendered bluer than the photo, London Rain
    /// warmer, and auto grade and the white-balance picker pushed a cast
    /// further instead of removing it. The look's light belongs in the target.
    static func shiftWhite(_ image: CIImage, towards kelvin: CGFloat, tint: CGFloat) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: tint)
        filter.targetNeutral = CIVector(x: kelvin, y: 0)
        return filter.outputImage ?? image
    }

    // MARK: - Built-in look recipes

    /// `trueColour` is the switch position: the live one unless a caller
    /// baking a batch of cubes holds it still (PackInstaller.cubeText).
    func applyRecipe(_ recipe: LookRecipe, to image: CIImage,
                     trueColour: Bool = TrueColour.isOn) -> CIImage {
        var output = image

        if recipe.temperature != 6500 || recipe.tint != 0 {
            output = Self.shiftWhite(output, towards: CGFloat(recipe.temperature),
                                     tint: CGFloat(recipe.tint))
        }

        // Saturation, contrast and brightness: the True Colour tone cube.
        // This used to be CIColorControls, which works in linear light: its
        // contrast pivots at a light grey and crushed deep skin to black, and
        // its brightness greyed it. See TrueColour.swift.
        if let tone = TrueColour.toneFilter(contrast: recipe.contrast,
                                            saturation: recipe.saturation,
                                            brightness: recipe.brightness,
                                            protectSkin: trueColour) {
            tone.setValue(output, forKey: kCIInputImageKey)
            output = tone.outputImage ?? output
        }

        if recipe.bloom > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output.clampedToExtent()
            bloom.intensity = recipe.bloom
            bloom.radius = Float(8 * Self.sizeScale(image.extent))
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

        // Exposure, Contrast and Saturation sliders: the same True Colour
        // tone as the looks, so the Contrast slider no longer crushes deep
        // skin and Exposure no longer greys it.
        let hasColourChange = settings.exposure != 0 || settings.contrast != 10 || settings.saturation != 0
        if hasColourChange,
           let tone = TrueColour.toneFilter(contrast: Float(1.0 + (settings.contrast - 10) / 200.0),
                                            saturation: Float(1.0 + settings.saturation / 100.0),
                                            brightness: Float(settings.exposure / 300.0)) {
            tone.setValue(output, forKey: kCIInputImageKey)
            output = tone.outputImage ?? output
        }

        if settings.warmth != 0 || settings.tint != 0 {
            output = Self.shiftWhite(output, towards: 6500 - CGFloat(settings.warmth) * 20,
                                     tint: CGFloat(settings.tint))
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
        if let splitCube = ColorMath.splitToneCube(settings.splitTone) {
            splitCube.setValue(output, forKey: kCIInputImageKey)
            output = splitCube.outputImage?.cropped(to: image.extent) ?? output
        }

        if settings.bloom > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output.clampedToExtent()
            bloom.intensity = Float(settings.bloom / 100.0)
            bloom.radius = Float(10 * Self.sizeScale(image.extent))
            output = bloom.outputImage?.cropped(to: image.extent) ?? output
        }

        if settings.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = output
            vignette.intensity = Float(settings.vignette / 100.0 * 1.5)
            vignette.radius = 2.0
            output = vignette.outputImage ?? output
        }

        // Shadows and Highlights: one curve on lightness (TrueColour), so
        // deep skin keeps its colour when shadows are pulled down, the two
        // sliders are as strong as each other, and an exported cube carries
        // them exactly. They used to be CIHighlightShadowAdjust.
        if settings.shadows != 0 || settings.highlights != 0,
           let curve = TrueColour.shadowHighlightFilter(shadows: settings.shadows / 100.0,
                                                        highlights: settings.highlights / 100.0) {
            curve.setValue(output, forKey: kCIInputImageKey)
            output = curve.outputImage ?? output
        }

        // Fade: lifted blacks, the matte-film look.
        if settings.fade > 0 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            let lift = CGFloat(settings.fade / 100.0 * 0.12)
            curve.point0 = CGPoint(x: 0, y: lift)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 + lift * 0.5)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.8, y: 0.8)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }

        if settings.sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = output
            sharpen.sharpness = Float(settings.sharpness / 100.0 * 0.9)
            // 1.69 is the filter's own radius, kept for the big picture.
            sharpen.radius = Float(max(0.5, 1.69 * Self.sizeScale(image.extent)))
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
        // Everything below the threshold comes out of that matrix NEGATIVE.
        // Unclamped, the glow below took red out of the whole frame instead
        // of adding it around the highlights: Halation at 50 turned mid grey
        // into teal (0, 91, 120) and deep skin into black. The mask is
        // highlights only, so it stops at zero.
        guard let highlights = threshold.outputImage?
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ]) else { return image }

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

        // A grain is 1.6 pixels across on the big picture (slightly coarser
        // than 1:1, so it reads as grain, not sensor noise) and keeps that
        // share of the frame at every size. It cannot be finer than a pixel:
        // on a small tile each pixel holds several grains, which average
        // out, so there the grain fades instead of staying pixel-sharp.
        let cell = 1.6 * Self.sizeScale(image.extent)
        let size = max(1, cell)

        // Monochrome the noise and centre it on mid-grey for overlay blend.
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise.transformed(by: CGAffineTransform(scaleX: size, y: size))
        let amp = CGFloat(0.28 * strength) * min(1, cell)
        mono.rVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        mono.gVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        mono.bVector = CIVector(x: amp, y: 0, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 1)
        guard let grainField = mono.outputImage?
            .applyingGaussianBlur(sigma: 0.25 * size)
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
