import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum GIFExporterError: Error, LocalizedError {
    case noFrames
    case destinationFailed

    var errorDescription: String? {
        switch self {
        case .noFrames: return "There were no frames to put in the GIF."
        case .destinationFailed: return "Could not write the GIF file."
        }
    }
}

/// F5, both directions: mov→GIF transcode for export, and an animated-GIF
/// decoder for the compositor's animated-still cache.
///
/// Everything here is a pure function of its arguments — no app state, no
/// main-actor hops — so `decodeFrames` is safe to call straight from the
/// compositor's render queue and `export` from any detached task. Nothing is
/// cached at this level on purpose: the frames belong to the compositor's own
/// bounded cache, and a transcode is a one-shot.
enum GIFExporter {
    /// GIF stores delays in hundredths of a second and every renderer on earth
    /// treats 0 as "as fast as possible", which spins a sticker into a blur.
    /// Floor at 20 ms — the de-facto browser minimum.
    private static let delayFloor: Double = 0.02

    // MARK: - Export

    /// Renders `asset` (optionally through `videoComposition`) to an animated GIF.
    /// `maxSeconds` trails the briefed signature with a permissive default, so the
    /// documented `export(asset:videoComposition:to:fps:maxWidth:)` call still binds.
    @discardableResult
    static func export(asset: AVAsset, videoComposition: AVVideoComposition?,
                       to outputURL: URL, fps: Double = 12, maxWidth: CGFloat = 480,
                       maxSeconds: Double = .infinity) async throws -> URL {
        // Clamp: fps 0 would divide by zero, fps 200 would write a 10 ms delay
        // the format cannot represent.
        let safeFPS = min(max(fps, 1), 50)
        let frameDelay = 1.0 / safeFPS

        let duration = try await asset.load(.duration)
        var seconds = duration.seconds
        // A live/indefinite asset reports NaN or +inf — refuse rather than
        // striding forever.
        guard seconds.isFinite, seconds > 0 else { throw GIFExporterError.noFrames }
        seconds = min(seconds, max(maxSeconds, frameDelay))

        let generator = AVAssetImageGenerator(asset: asset)
        // A videoComposition already bakes the track transform into its own
        // renderSize; asking for the preferred transform on top of it rotates
        // twice. Only opt in on the raw-asset path.
        generator.appliesPreferredTrackTransform = (videoComposition == nil)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Aspect is preserved inside the box, so the tall height just lets width
        // be the only real cap.
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 10)
        if let videoComposition {
            generator.videoComposition = videoComposition
        }

        let times = stride(from: 0.0, to: seconds, by: frameDelay)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !times.isEmpty else { throw GIFExporterError.noFrames }

        // Stale file first: the destination only truncates on finalize, so a
        // failed run could otherwise leave a longer old GIF's tail behind.
        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw GIFExporterError.destinationFailed
        }

        // Loop count 0 == forever.
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ] as CFDictionary

        // Add each frame as it arrives — holding 180 CGImages of a 480 px GIF
        // before writing costs ~100 MB for nothing.
        var written = 0
        for time in times {
            try Task.checkCancellation()
            // One unreadable time (a ragged tail, a gap between clips) must not
            // sink the whole transcode — skip it and carry on.
            guard let result = try? await generator.image(at: time) else { continue }
            CGImageDestinationAddImage(destination, result.image, frameProperties)
            written += 1
        }

        guard written > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw GIFExporterError.noFrames
        }
        guard CGImageDestinationFinalize(destination) else {
            // Never leave a half-written GIF for the share sheet to find.
            try? FileManager.default.removeItem(at: outputURL)
            throw GIFExporterError.destinationFailed
        }
        return outputURL
    }

    /// Convenience for the post-export hook: transcode a finished .mov in tmp.
    /// Non-throwing — the GIF is a bonus artefact and must never turn a
    /// successful video export into an error the user sees.
    static func makeGIF(from movURL: URL, fps: Double = 12, maxWidth: CGFloat = 480,
                        maxSeconds: Double = 15) async -> URL? {
        // "LumaLook_Export_" prefix so VideoExporter.cleanUpStaleExports sweeps
        // abandoned GIFs on the next launch like every other export artefact.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Export_\(UUID().uuidString).gif")
        return try? await export(asset: AVURLAsset(url: movURL), videoComposition: nil,
                                 to: outputURL, fps: fps, maxWidth: maxWidth,
                                 maxSeconds: maxSeconds)
    }

    // MARK: - Decode

    /// Decodes an animated GIF into its frames + per-frame delays (for looping
    /// stickers). Returns nil for a file ImageIO cannot open or that holds no
    /// images — callers fall back to the plain still path.
    static func decodeFrames(at url: URL) -> (frames: [CGImage], delays: [Double])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [CGImage] = []
        var delays: [Double] = []
        frames.reserveCapacity(count)
        delays.reserveCapacity(count)
        for index in 0..<count {
            // Keep frames and delays index-aligned: a frame we cannot decode
            // drops its delay too.
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(image)
            delays.append(delay(source: source, index: index))
        }
        guard !frames.isEmpty else { return nil }
        return (frames, delays)
    }

    /// Unclamped first: encoders routinely write 0 into DelayTime and stash the
    /// real timing in UnclampedDelayTime.
    private static func delay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return delayFloor
        }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? 0
        let clamped = (gif[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0
        return max(unclamped > 0 ? unclamped : clamped, delayFloor)
    }
}
