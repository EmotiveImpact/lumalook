import Foundation
import AVFoundation
import CoreImage
import Photos

enum VideoExportError: Error, LocalizedError {
    case exportSessionCreationFailed
    case exportFailed
    case noVideoSelected

    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed: return "Could not create the export session."
        case .exportFailed: return "The export failed. Please try again."
        case .noVideoSelected: return "Select a video from Photos first."
        }
    }
}

/// User-facing export options (queue #6). Remembered across sessions.
struct ExportSpec: Equatable {
    enum Resolution: String, CaseIterable { case hd1080 = "1080p", uhd4K = "4K" }
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }

    var resolution: Resolution = .hd1080
    var codec: Codec = .hevc
    var fps: Int = 30

    var presetName: String {
        switch (resolution, codec) {
        case (.hd1080, .h264): return AVAssetExportPreset1920x1080
        case (.uhd4K, .h264): return AVAssetExportPreset3840x2160
        case (.hd1080, .hevc): return AVAssetExportPresetHEVC1920x1080
        case (.uhd4K, .hevc): return AVAssetExportPresetHEVC3840x2160
        }
    }

    /// AppStorage-friendly encoding.
    var rawValue: String { "\(resolution.rawValue)|\(codec.rawValue)|\(fps)" }
    static func from(rawValue: String) -> ExportSpec {
        let parts = rawValue.split(separator: "|").map(String.init)
        var spec = ExportSpec()
        if parts.count == 3 {
            spec.resolution = Resolution(rawValue: parts[0]) ?? .hd1080
            spec.codec = Codec(rawValue: parts[1]) ?? .hevc
            spec.fps = Int(parts[2]) ?? 30
        }
        return spec
    }
}

@MainActor
final class VideoExporter: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExporting = false

    private var session: AVAssetExportSession?
    private var progressTask: Task<Void, Never>?

    /// Single-clip Apply-a-Look export.
    func export(videoURL: URL, lookState: LookState,
                spec: ExportSpec = ExportSpec()) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let pipeline = LookPipeline.shared

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            // includeSplit: false — the Before/After wipe never bakes into exports.
            let filtered = pipeline.apply(state: lookState, to: source, includeSplit: false)
            request.finish(with: filtered.cropped(to: request.sourceImage.extent), context: pipeline.context)
        }
        composition.applySDRColorPolicy()

        return try await export(asset: asset, videoComposition: composition, audioMix: nil, spec: spec)
    }

    /// Shared export path — also used for full editor timelines.
    func export(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?,
                spec: ExportSpec = ExportSpec()) async throws -> URL {
        // Frame-rate choice resamples the CI handler cadence.
        if let mutable = videoComposition as? AVMutableVideoComposition, spec.fps > 0 {
            mutable.frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
        }
        isExporting = true
        progress = 0
        defer {
            isExporting = false
            progressTask?.cancel()
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Export_\(UUID().uuidString).mov")

        guard let session = AVAssetExportSession(asset: asset, presetName: spec.presetName)
                ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw VideoExportError.exportSessionCreationFailed
        }
        self.session = session

        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.shouldOptimizeForNetworkUse = true

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                self.progress = Double(session.progress)
                if session.status == .completed || session.status == .failed { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await session.export()

        if session.status == .completed {
            progress = 1
            return outputURL
        } else if session.status == .cancelled {
            throw CancellationError()
        } else {
            throw session.error ?? VideoExportError.exportFailed
        }
    }

    func cancel() {
        session?.cancelExport()
    }

    func saveToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw VideoExportError.exportFailed
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
