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

        if let lut = state.lut {
            graded = applyLUT(lut, to: graded)
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

    // MARK: - LUT application

    func applyLUT(_ lut: ParsedLUT, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(lut.size)
        filter.cubeData = lut.rgbaFloatData
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return filter.outputImage ?? image
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
            bloom.inputImage = output
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

        if settings.bloom > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output
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

        // TODO: grain and halation need a custom kernel / compositing pass. P1.
        return output
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
        let graded = apply(state: state, to: input.clampedToExtent(), includeSplit: includeSplit)
            .cropped(to: input.extent)
        return context.createCGImage(graded, from: graded.extent,
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
