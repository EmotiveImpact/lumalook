import CoreImage
import CoreImage.CIFilterBuiltins

/// C8 — focus peaking: paints high-frequency (in-focus) edges in a hot
/// accent so manual focus is judged by eye on the viewfinder.
///
/// Preview-only — composited onto the HUD feed, never into recordings.
/// Pure function of (image, strength); deterministic, render-queue safe.
enum FocusPeakingRenderer {

    /// Overlay `image` with peaking marks. `strength` 0…1 sets the edge
    /// threshold (higher = only the crispest edges light up).
    static func apply(to image: CIImage, strength: Double = 0.5) -> CIImage {
        let rect = image.extent
        guard rect.width > 1, rect.height > 1, rect.width.isFinite, rect.height.isFinite else { return image }

        // Edge magnitude.
        let edges = CIFilter.edges()
        edges.inputImage = image
        edges.intensity = 4
        guard let edgeImage = edges.outputImage else { return image }

        // Luma of the edge response → alpha mask, hard-thresholded so peaking
        // reads as marks, not a glow. Threshold slides 0.18…0.62 with strength.
        let threshold = 0.18 + 0.44 * min(max(strength, 0), 1)
        let mask = edgeImage.applyingFilter("CIColorMatrix", parameters: [
            // Alpha := luma(RGB); RGB := 0 (premultiplied-valid transparent).
            // NB row semantics: each vector is dotted with source RGBA — the
            // luma weights must live in the ALPHA row, not the colour rows.
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorPolynomial", parameters: [
            // Steep step around the threshold: a ≈ 0 below, 1 above.
            "inputAlphaCoefficients": CIVector(x: -threshold * 8, y: 8, z: 0, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        // Hot marker colour (the app's accent red-orange) through the mask.
        let marker = CIImage(color: CIColor(red: 1.0, green: 0.23, blue: 0.19))
            .cropped(to: rect)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask.cropped(to: rect),
            ])

        return marker.composited(over: image).cropped(to: rect)
    }
}
