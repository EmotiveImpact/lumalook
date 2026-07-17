import AVFoundation
import CoreVideo

enum ClipBakerError: Error {
    case noVideoTrack
    case readerFailed
    case writerFailed
}

/// Offline media rewrites that can't be expressed as a composition — today
/// just clip reversal. Runs off the main actor; the caller swaps the clip's
/// URL to the baked file on completion.
enum ClipBaker {

    /// Reverses the trimmed range of `url` into a new file at `outputURL`.
    /// Video is decoded in bounded time-ranged chunks (last chunk first, each
    /// chunk written back-to-front) so memory stays flat regardless of clip
    /// length. The reversed clip is silent by design — reversed audio is
    /// almost never wanted and PCM reversal is fragile across codecs. Returns
    /// `outputURL` on success.
    static func reverse(url: URL, trimStart: Double, trimEnd: Double,
                        outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipBakerError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFPS > 1 ? Double(nominalFPS) : 30.0
        let frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)

        let clampedStart = max(0, trimStart)
        let start = CMTime(seconds: clampedStart, preferredTimescale: 600)
        let end = CMTime(seconds: max(clampedStart + 0.05, trimEnd), preferredTimescale: 600)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // --- Video writer input -------------------------------------------
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(abs(naturalSize.width).rounded()),
            AVVideoHeightKey: Int(abs(naturalSize.height).rounded()),
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(abs(naturalSize.width).rounded()),
                kCVPixelBufferHeightKey as String: Int(abs(naturalSize.height).rounded()),
            ])
        guard writer.canAdd(videoInput) else { throw ClipBakerError.writerFailed }
        writer.add(videoInput)

        guard writer.startWriting() else { throw ClipBakerError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        // --- Reverse the video, chunk by chunk ----------------------------
        try await reverseVideo(asset: asset, track: videoTrack, writer: writer,
                               fullRange: CMTimeRange(start: start, end: end),
                               frameDuration: frameDuration,
                               adaptor: adaptor, input: videoInput)
        videoInput.markAsFinished()

        await writer.finishWriting()
        if writer.status == .completed { return outputURL }
        throw ClipBakerError.writerFailed
    }

    // MARK: - Video

    private static func reverseVideo(asset: AVAsset, track: AVAssetTrack, writer: AVAssetWriter,
                                     fullRange: CMTimeRange, frameDuration: CMTime,
                                     adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                     input: AVAssetWriterInput) async throws {
        // Walk the source range in fixed chunks from the END to the START; in
        // each chunk buffer the decoded frames then append them back-to-front.
        let chunk = CMTime(seconds: 0.5, preferredTimescale: 600)
        var chunkStarts: [CMTime] = []
        var t = fullRange.start
        while t < fullRange.end {
            chunkStarts.append(t)
            t = t + chunk
        }

        var outputPTS = CMTime.zero
        for chunkStart in chunkStarts.reversed() {
            let chunkEnd = CMTimeMinimum(chunkStart + chunk, fullRange.end)
            let range = CMTimeRange(start: chunkStart, end: chunkEnd)
            let frames = try readPixelBuffers(asset: asset, track: track, range: range)
            for buffer in frames.reversed() {
                await waitForReady(input, writer: writer)
                if writer.status == .failed { throw ClipBakerError.writerFailed }
                adaptor.append(buffer, withPresentationTime: outputPTS)
                outputPTS = outputPTS + frameDuration
            }
        }
    }

    /// Decodes every frame in `range` into an array of BGRA pixel buffers.
    private static func readPixelBuffers(asset: AVAsset, track: AVAssetTrack,
                                         range: CMTimeRange) throws -> [CVPixelBuffer] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipBakerError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw ClipBakerError.readerFailed }

        var buffers: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let px = CMSampleBufferGetImageBuffer(sample) {
                // Deep-copy: the reader recycles its pool once we release.
                if let copy = deepCopyPixelBuffer(px) { buffers.append(copy) }
            }
        }
        reader.cancelReading()
        return buffers
    }

    private static func deepCopyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        var dst: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attrs as CFDictionary, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        if CVPixelBufferIsPlanar(src) {
            for plane in 0..<CVPixelBufferGetPlaneCount(src) {
                guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                    * CVPixelBufferGetHeightOfPlane(src, plane)
                memcpy(d, s, bytes)
            }
        } else if let s = CVPixelBufferGetBaseAddress(src),
                  let d = CVPixelBufferGetBaseAddress(dst) {
            memcpy(d, s, CVPixelBufferGetBytesPerRow(src) * height)
        }
        return dst
    }

    // MARK: - Backpressure

    /// Spins until the writer input can accept more media, bailing if the
    /// writer fails (assetwriter inputs have no async ready signal, so a short
    /// sleep avoids a busy loop and a failed writer can never hang the bake).
    private static func waitForReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
